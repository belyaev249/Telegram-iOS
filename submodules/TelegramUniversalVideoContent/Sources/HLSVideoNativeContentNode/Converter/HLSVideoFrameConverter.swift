import Accelerate
import MetalKit
import FFMpegBinding

private final class PrivateBundle: NSObject {
}

final class HLSVideoFrameConverter {
    private let device: MTLDevice
    private let library: MTLLibrary

    private let commandQueue: MTLCommandQueue
    private let kernelFunction: MTLFunction

    private var uvPlane: (UnsafeMutablePointer<UInt8>, Int)?
    
    init?() {
        let mainBundle = Bundle(for: PrivateBundle.self)
        
        guard let path = mainBundle.path(forResource: "TelegramUniversalVideoContentBundle", ofType: "bundle") else {
            return nil
        }
        
        guard let bundle = Bundle(path: path) else {
            return nil
        }
        
        guard let device = MTLCreateSystemDefaultDevice(),
            let library = try? device.makeDefaultLibrary(bundle: bundle),
            let commandQueue = device.makeCommandQueue(),
            let kernelFunction = library.makeFunction(name: "fillPlane")
        else {
            return nil
        }
                
        self.device = device
        self.library = library
        self.commandQueue = commandQueue
        self.kernelFunction = kernelFunction
    }
    
    func flush() {
        uvPlane?.0.deallocate()
        uvPlane = nil
    }

    private func fillDstPlane(dstPlane: UnsafeMutablePointer<UInt8>, dstPlaneSize: Int, srcPlane1: UnsafeMutablePointer<UInt8>, srcPlane2: UnsafeMutablePointer<UInt8>, srcPlaneSize: Int) {
        if srcPlaneSize == 0 { return }
        
        guard let commandBuffer = commandQueue.makeCommandBuffer(),
              let computeCommandEncoder = commandBuffer.makeComputeCommandEncoder()
        else {
            return
        }
        
        guard let computePipelineState = try? device.makeComputePipelineState(function: kernelFunction) else {
            computeCommandEncoder.endEncoding()
            return
        }
        computeCommandEncoder.setComputePipelineState(computePipelineState)
        
        let dstPlaneBuffer = device.makeBuffer(bytes: dstPlane, length: MemoryLayout<UInt8>.size * dstPlaneSize, options: .storageModeShared)
        let srcPlane1Buffer = device.makeBuffer(bytes: srcPlane1, length: MemoryLayout<UInt8>.size * srcPlaneSize, options: .storageModeShared)
        let srcPlane2Buffer = device.makeBuffer(bytes: srcPlane2, length: MemoryLayout<UInt8>.size * srcPlaneSize, options: .storageModeShared)
        
        computeCommandEncoder.setBuffer(dstPlaneBuffer, offset: 0, index: 0)
        computeCommandEncoder.setBuffer(srcPlane1Buffer, offset: 0, index: 1)
        computeCommandEncoder.setBuffer(srcPlane2Buffer, offset: 0, index: 2)
        var srcPlaneSize = srcPlaneSize
        computeCommandEncoder.setBytes(&srcPlaneSize, length: MemoryLayout<Int>.size, index: 3)
        
        var threadGroupSize = computePipelineState.maxTotalThreadsPerThreadgroup
        if (threadGroupSize > srcPlaneSize) {
            threadGroupSize = Int(srcPlaneSize)
        }
        let gridSize = (srcPlaneSize + threadGroupSize - 1) / threadGroupSize
        
        let threadsPerGroup = MTLSize(width: threadGroupSize, height: 1, depth: 1)
        let numThreadGroups = MTLSize(width: gridSize, height: 1, depth: 1)
        
        computeCommandEncoder.dispatchThreadgroups(numThreadGroups, threadsPerThreadgroup: threadsPerGroup)
        computeCommandEncoder.endEncoding()
        
        commandBuffer.addCompletedHandler { _ in
            memcpy(dstPlane, dstPlaneBuffer?.contents(), dstPlaneSize)
            dstPlaneBuffer?.setPurgeableState(.empty)
            srcPlane1Buffer?.setPurgeableState(.empty)
            srcPlane2Buffer?.setPurgeableState(.empty)
        }
                    
        commandBuffer.commit()
        commandBuffer.waitUntilCompleted()
    }
    
    func convertFrame(frame: FFMpegAVFrame, completion: @escaping (CVPixelBuffer) -> Bool) -> Bool? {
        if frame.data[0] == nil {
            return nil
        }
        if frame.lineSize[1] != frame.lineSize[2] {
            return nil
        }
        
        var pixelBufferRef: CVPixelBuffer?
        
        let pixelFormat: OSType
        switch frame.pixelFormat {
        case FFMpegAVFramePixelFormat.YUVA:
            pixelFormat = kCVPixelFormatType_420YpCbCr8VideoRange_8A_TriPlanar
        default:
            pixelFormat = kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange
        }
        
        let ioSurfaceProperties = NSMutableDictionary()
        ioSurfaceProperties["IOSurfaceIsGlobal"] = true as NSNumber
        
        var options: [String: Any] = [kCVPixelBufferBytesPerRowAlignmentKey as String: frame.lineSize[0] as NSNumber]
        options[kCVPixelBufferIOSurfacePropertiesKey as String] = ioSurfaceProperties
        
        CVPixelBufferCreate(kCFAllocatorDefault,
                            Int(frame.width),
                            Int(frame.height),
                            pixelFormat,
                            options as CFDictionary,
                            &pixelBufferRef)
        
        guard let pixelBuffer = pixelBufferRef else {
            return nil
        }
        
        let status = CVPixelBufferLockBaseAddress(pixelBuffer, [])
        if status != kCVReturnSuccess {
            return nil
        }
        
        var base: UnsafeMutableRawPointer
        if pixelFormat == kCVPixelFormatType_32ARGB {
    //        let bytesPerRow = CVPixelBufferGetBytesPerRow(pixelBuffer)
    //        decodeYUVAPlanesToRGBA(frame.data[0], Int32(frame.lineSize[0]), frame.data[1], Int32(frame.lineSize[1]), frame.data[2], Int32(frame.lineSize[2]), hasAlpha, frame.data[3], CVPixelBufferGetBaseAddress(pixelBuffer)?.assumingMemoryBound(to: UInt8.self), Int32(frame.width), Int32(frame.height), Int32(bytesPerRow), unpremultiplyAlpha)
        } else {
            let srcPlaneSize = Int(frame.lineSize[1]) * Int(frame.height / 2)
            let uvPlaneSize = srcPlaneSize * 2
            
            let uvPlane: UnsafeMutablePointer<UInt8>
            if let (existingUvPlane, existingUvPlaneSize) = self.uvPlane, existingUvPlaneSize == uvPlaneSize {
                uvPlane = existingUvPlane
            } else {
                if let (existingDstPlane, _) = self.uvPlane {
                    free(existingDstPlane)
                }
                uvPlane = malloc(uvPlaneSize)!.assumingMemoryBound(to: UInt8.self)
                self.uvPlane = (uvPlane, uvPlaneSize)
            }
            fillDstPlane(dstPlane: uvPlane, dstPlaneSize: uvPlaneSize, srcPlane1: frame.data[1]!, srcPlane2: frame.data[2]!, srcPlaneSize: srcPlaneSize)
            
            let bytesPerRowY = CVPixelBufferGetBytesPerRowOfPlane(pixelBuffer, 0)
            let bytesPerRowUV = CVPixelBufferGetBytesPerRowOfPlane(pixelBuffer, 1)
            let bytesPerRowA = CVPixelBufferGetBytesPerRowOfPlane(pixelBuffer, 2)
            
            var requiresAlphaMultiplication = false
            
            if pixelFormat == kCVPixelFormatType_420YpCbCr8VideoRange_8A_TriPlanar {
                requiresAlphaMultiplication = true
                
                base = CVPixelBufferGetBaseAddressOfPlane(pixelBuffer, 2)!
                if bytesPerRowA == frame.lineSize[3] {
                    memcpy(base, frame.data[3]!, bytesPerRowA * Int(frame.height))
                } else {
                    var dest = base
                    var src = frame.data[3]!
                    let lineSize = Int(frame.lineSize[3])
                    for _ in 0 ..< Int(frame.height) {
                        memcpy(dest, src, lineSize)
                        dest = dest.advanced(by: bytesPerRowA)
                        src = src.advanced(by: lineSize)
                    }
                }
            }
            
            base = CVPixelBufferGetBaseAddressOfPlane(pixelBuffer, 0)!
            if bytesPerRowY == frame.lineSize[0] {
                memcpy(base, frame.data[0], bytesPerRowY * Int(frame.height))
            } else {
                var dest = base
                var src = frame.data[0]
                let lineSize = Int(frame.lineSize[0])
                for _ in 0 ..< Int(frame.height) {
                    memcpy(dest, src, lineSize)
                    dest = dest.advanced(by: bytesPerRowY)
                    src = src?.advanced(by: lineSize)
                }
            }
            
            if requiresAlphaMultiplication {
                var y = vImage_Buffer(data: CVPixelBufferGetBaseAddressOfPlane(pixelBuffer, 0)!, height: vImagePixelCount(frame.height), width: vImagePixelCount(bytesPerRowY), rowBytes: bytesPerRowY)
                var a = vImage_Buffer(data: CVPixelBufferGetBaseAddressOfPlane(pixelBuffer, 2)!, height: vImagePixelCount(frame.height), width: vImagePixelCount(bytesPerRowY), rowBytes: bytesPerRowA)
                let _ = vImagePremultiplyData_Planar8(&y, &a, &y, vImage_Flags(kvImageDoNotTile))
            }
            
            base = CVPixelBufferGetBaseAddressOfPlane(pixelBuffer, 1)!
            if bytesPerRowUV == frame.lineSize[1] * 2 {
                memcpy(base, uvPlane, Int(frame.height / 2) * bytesPerRowUV)
            } else {
                var dest = base
                var src = uvPlane
                let lineSize = Int(frame.lineSize[1]) * 2
                for _ in 0 ..< Int(frame.height / 2) {
                    memcpy(dest, src, lineSize)
                    dest = dest.advanced(by: bytesPerRowUV)
                    src = src.advanced(by: lineSize)
                }
            }
        }
        CVPixelBufferUnlockBaseAddress(pixelBuffer, [])
        return completion(pixelBuffer)
    }
}
