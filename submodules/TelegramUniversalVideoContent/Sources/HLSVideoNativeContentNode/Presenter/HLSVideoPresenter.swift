import MetalKit
import Accelerate
import AVFoundation

private final class PrivateBundle: NSObject {
}

final class HLSVideoPresenter: MTKView {
    private let renderer: HLSVideoRenderer?
                
    init(videoOutputTransport: OutputTransport) {
        self.renderer = HLSVideoRenderer(videoOutputTransport)
        
        super.init(frame: .zero, device: renderer?.device)
                
        self.isUserInteractionEnabled = false
        self.isPaused = true
        self.enableSetNeedsDisplay = false
        self.framebufferOnly = true
        
        self.clearColor = .init(red: 1, green: 1, blue: 1, alpha: 1)
        self.delegate = renderer
    }
    
    required init(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }
}

private final class HLSVideoRenderer: NSObject, MTKViewDelegate {
    let device: MTLDevice
    let library: MTLLibrary
    let commandQueue: MTLCommandQueue
    
    private weak var videoOutputTransport: OutputTransport?
    private let vertexFunction: MTLFunction
        
    init?(_ videoOutputTransport: OutputTransport) {
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
              let vertexFunction = library.makeFunction(name: "mapTexture")
        else {
            return nil
        }
        
        self.device = device
        self.library = library
        self.commandQueue = commandQueue
        self.videoOutputTransport = videoOutputTransport
        self.vertexFunction = vertexFunction
    }
    
    required init(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }
    
    func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize) {
    }
    
    func draw(in view: MTKView) {
        autoreleasepool {
            guard let videoFrame = videoOutputTransport?.getVideoOutput() else {
                return
            }
            let pixelBuffer = videoFrame.buffer
            let inputTextures = Self.texture(pixelBuffer: pixelBuffer, device: device)
            
            let par = pixelBuffer.size
            let sar = pixelBuffer.aspectRatio
            
            let size: CGSize
            if /* ==plane */ true {
                size = CGSize(width: par.width, height: par.height * sar.height / sar.width)
            } else {
                size = UIApplication.shared.keyWindow?.bounds.size ?? .zero
            }
            
            view.drawableSize = size
            view.colorPixelFormat = Self.colorPixelFormat(bitDepth: pixelBuffer.bitDepth)
            
            guard let commandBuffer = commandQueue.makeCommandBuffer(),
                  let currentDrawable = view.currentDrawable,
                  let currentRenderPassDescriptor = view.currentRenderPassDescriptor,
                  let renderCommandEncoder = commandBuffer.makeRenderCommandEncoder(descriptor: currentRenderPassDescriptor)
            else {
                return
            }
            
            currentRenderPassDescriptor.colorAttachments[0].texture = currentDrawable.texture
            
            guard let renderPipelineState = pipelineState(planeCount: pixelBuffer.planeCount, bitDepth: pixelBuffer.bitDepth) else {
                renderCommandEncoder.endEncoding()
                return
            }
            
            renderCommandEncoder.setRenderPipelineState(renderPipelineState)
            renderCommandEncoder.setFragmentSamplerState(samplerState, index: 0)
            for (index, texture) in inputTextures.enumerated() {
//                texture.label = "texture\(index)"
                renderCommandEncoder.setFragmentTexture(texture, index: index)
            }
            
            setVertexBuffer(pixelBuffer: pixelBuffer, encoder: renderCommandEncoder)
            
            renderCommandEncoder.endEncoding()
            commandBuffer.present(currentDrawable)
            commandBuffer.commit()
            
            videoOutputTransport?.setVideo(time: videoFrame.cmtime, position: videoFrame.position)
        }
    }
    
    private static func vertices() -> ([UInt16], [simd_float4], [simd_float2]) {
        let indices: [UInt16] = [0, 1, 2, 3]
        let positions: [simd_float4] = [
            [-1.0, -1.0, 0.0, 1.0],
            [-1.0, 1.0, 0.0, 1.0],
            [1.0, -1.0, 0.0, 1.0],
            [1.0, 1.0, 0.0, 1.0],
        ]
        let uvs: [simd_float2] = [
            [0.0, 1.0],
            [0.0, 0.0],
            [1.0, 1.0],
            [1.0, 0.0],
        ]
        return (indices, positions, uvs)
    }
    
    private static let (indices, positions, uvs) = vertices()
    private static let indexCount = indices.count
    private lazy var indexBuffer = device.makeBuffer(bytes: Self.indices, length: MemoryLayout<UInt16>.size * Self.indexCount)!
    private lazy var posBuffer = device.makeBuffer(bytes: Self.positions, length: MemoryLayout<simd_float4>.size * Self.positions.count)
    private lazy var uvBuffer = device.makeBuffer(bytes: Self.uvs, length: MemoryLayout<simd_float2>.size * Self.uvs.count)
    
    private func setVertexBuffer(pixelBuffer: CVPixelBuffer, encoder: MTLRenderCommandEncoder) {
        encoder.setFrontFacing(.clockwise)
        encoder.setVertexBuffer(posBuffer, offset: 0, index: 0)
        encoder.setVertexBuffer(uvBuffer, offset: 0, index: 1)
        encoder.drawIndexedPrimitives(type: .triangleStrip, indexCount: Self.indexCount, indexType: .uint16, indexBuffer: indexBuffer, indexBufferOffset: 0)
    }
    
    private lazy var samplerState: MTLSamplerState? = {
        let samplerDescriptor = MTLSamplerDescriptor()
        samplerDescriptor.minFilter = .linear
        samplerDescriptor.magFilter = .linear
        return device.makeSamplerState(descriptor: samplerDescriptor)
    }()
    
    private lazy var yuv = makePipelineState(fragmentFunction: "displayYUVTexture", bitDepth: 8)
    private lazy var yuvp010LE = makePipelineState(fragmentFunction: "displayYUVTexture", bitDepth: 10)
    private lazy var nv12 = makePipelineState(fragmentFunction: "displayNV12Texture", bitDepth: 8)
    private lazy var p010LE = makePipelineState(fragmentFunction: "displayNV12Texture", bitDepth: 10)
    private lazy var bgra = makePipelineState(fragmentFunction: "displayTexture", bitDepth: 8)
    
    private func makePipelineState(fragmentFunction: String, bitDepth: Int32) -> MTLRenderPipelineState? {
        let renderPipelineDescriptor = MTLRenderPipelineDescriptor()
        renderPipelineDescriptor.colorAttachments[0].pixelFormat = Self.colorPixelFormat(bitDepth: bitDepth)
        renderPipelineDescriptor.vertexFunction = vertexFunction
        
        let fragmentFunction = library.makeFunction(name: fragmentFunction)
        renderPipelineDescriptor.fragmentFunction = fragmentFunction
        
        let vertexDescriptor = MTLVertexDescriptor()
        vertexDescriptor.attributes[0].format = .float4
        vertexDescriptor.attributes[0].bufferIndex = 0
        vertexDescriptor.attributes[0].offset = 0
        vertexDescriptor.attributes[1].format = .float2
        vertexDescriptor.attributes[1].bufferIndex = 1
        vertexDescriptor.attributes[1].offset = 0
        vertexDescriptor.layouts[0].stride = MemoryLayout<simd_float4>.stride
        vertexDescriptor.layouts[1].stride = MemoryLayout<simd_float2>.stride
        renderPipelineDescriptor.vertexDescriptor = vertexDescriptor
        
        do {
            return try device.makeRenderPipelineState(descriptor: renderPipelineDescriptor)
        } catch {
            return nil
        }
    }
    
    private func pipelineState(planeCount: Int, bitDepth: Int32) -> MTLRenderPipelineState? {
        switch planeCount {
        case 3:
            if bitDepth == 10 {
                return yuvp010LE
            } else {
                return yuv
            }
        case 2:
            if bitDepth == 10 {
                return p010LE
            } else {
                return nv12
            }
        case 1:
            return bgra
        default:
            return bgra
        }
    }
    
    private static func texture(pixelBuffer: CVPixelBuffer, device: MTLDevice) -> [MTLTexture] {
        guard let iosurface = CVPixelBufferGetIOSurface(pixelBuffer)?.takeUnretainedValue() else {
            return []
        }
        let planeCount = pixelBuffer.planeCount
        let bitDepth = pixelBuffer.bitDepth
        let formats = pixelFormat(planeCount: planeCount, bitDepth: bitDepth)
        return (0 ..< planeCount).compactMap { index in
            let width = CVPixelBufferGetWidthOfPlane(pixelBuffer, index)
            let height = CVPixelBufferGetHeightOfPlane(pixelBuffer, index)
            let descriptor = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: formats[index], width: width, height: height, mipmapped: false)
            return device.makeTexture(descriptor: descriptor, iosurface: iosurface, plane: index)
        }
    }
    
    private static func pixelFormat(planeCount: Int, bitDepth: Int32) -> [MTLPixelFormat] {
        if planeCount == 3 {
            if bitDepth > 8 {
                return [.r16Unorm, .r16Unorm, .r16Unorm]
            } else {
                return [.r8Unorm, .r8Unorm, .r8Unorm]
            }
        } else if planeCount == 2 {
            if bitDepth > 8 {
                return [.r16Unorm, .rg16Unorm]
            } else {
                return [.r8Unorm, .rg8Unorm]
            }
        } else {
            return [colorPixelFormat(bitDepth: bitDepth)]
        }
    }
    
    private static func colorPixelFormat(bitDepth: Int32) -> MTLPixelFormat {
        if bitDepth == 10 {
            return .bgr10a2Unorm
        } else {
            return .bgra8Unorm
        }
    }
}

private extension UIApplication {
    var keyWindow: UIWindow? {
        windows.first(where: { $0.isKeyWindow })
    }
}

private extension CVPixelBuffer {
    var leftShift: UInt8 { 0 }
    
    var width: Int {
        CVPixelBufferGetWidth(self)
    }
    
    var height: Int {
        CVPixelBufferGetHeight(self)
    }
    
    var size: CGSize {
        CGSize(width: width, height: height)
    }
    
    var planeCount: Int {
        CVPixelBufferGetPlaneCount(self)
    }
    
    var bitDepth: Int32 {
        CVPixelBufferGetPixelFormatType(self).bitDepth
    }
    
    var aspectRatio: CGSize {
        get {
            if let ratio = CVBufferGetAttachment(self, kCVImageBufferPixelAspectRatioKey, nil)?.takeUnretainedValue() as? NSDictionary,
               let horizontal = (ratio[kCVImageBufferPixelAspectRatioHorizontalSpacingKey] as? NSNumber)?.intValue,
               let vertical = (ratio[kCVImageBufferPixelAspectRatioVerticalSpacingKey] as? NSNumber)?.intValue,
               horizontal > 0, vertical > 0
            {
                return CGSize(width: horizontal, height: vertical)
            } else {
                return CGSize(width: 1, height: 1)
            }
        }
        set {
            if let aspectRatio = newValue.aspectRatio {
                CVBufferSetAttachment(self, kCVImageBufferPixelAspectRatioKey, aspectRatio, .shouldPropagate)
            }
        }
    }
}

private extension CGSize {
    var aspectRatio: NSDictionary? {
        if width != 0, height != 0, width != height {
            return [kCVImageBufferPixelAspectRatioHorizontalSpacingKey: width,
                    kCVImageBufferPixelAspectRatioVerticalSpacingKey: height]
        } else {
            return nil
        }
    }
}

private extension OSType {
    var bitDepth: Int32 {
        switch self {
        case kCVPixelFormatType_420YpCbCr10BiPlanarVideoRange, kCVPixelFormatType_422YpCbCr10BiPlanarVideoRange, kCVPixelFormatType_444YpCbCr10BiPlanarVideoRange, kCVPixelFormatType_420YpCbCr10BiPlanarFullRange, kCVPixelFormatType_422YpCbCr10BiPlanarFullRange, kCVPixelFormatType_444YpCbCr10BiPlanarFullRange:
            return 10
        default:
            return 8
        }
    }
}
