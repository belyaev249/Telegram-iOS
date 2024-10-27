import AVFoundation

final class HLSVideoAssetBuffer {
    private let decodeQueue = DispatchQueue(label: "com.decode.queue", qos: .userInteractive)
    private let frameDecoder = HLSVideoAssetFrameDecoder()
    private let numberOfAssetsToKeepInMemory: Int
    
    private var didSetupWithParameters: ((_ frameRate: Int32?, _ audioFormat: AVAudioFormat?) -> Void)?
    private var didChangeFrames: ((_ startTime: Int64?, _ timeFromStart: Int64?) -> Void)?
    
    private var currentAssetIndex = -1
    private var assets: [HLSVideoAsset] = []
            
    init?(
        source: HLSServerSource,
        assetReferences: [HLSVideoAssetReference],
        numberOfAssetsToKeepInMemory: Int = 1,
        didSetupWithParameters: ((_ frameRate: Int32?, _ audioFormat: AVAudioFormat?) -> Void)? = nil,
        didChangeFrames: ((_ startTime: Int64?, _ timeFromStart: Int64?) -> Void)? = nil
    ) {
        if assetReferences.isEmpty { return nil}
        
        self.numberOfAssetsToKeepInMemory = numberOfAssetsToKeepInMemory
        self.didSetupWithParameters = didSetupWithParameters
        self.didChangeFrames = didChangeFrames
        
        for assetReference in assetReferences {
            let asset = HLSVideoAsset(
                source: source,
                frameDecoder: frameDecoder,
                urlSession: .shared,
                assetReference: assetReference,
                decodeQueue: decodeQueue,
                didSetupWithParameters: { [weak self] frameRate, startTime, duration, audioFormat in
                    self?.didSetupWithParameters?(frameRate, audioFormat)
                },
                didCompleteDecoding: {},
                didChangeFrames: { [weak self] time, startTime, possibleStartTime, progressOfDecode, isLastFrame in
                    let timeFromStart = (time?.value ?? 0) - (startTime ?? 0)
                    if isLastFrame {
                        self?.startDecodeNextAsset()
                    }
                    if progressOfDecode > 0.5 {
                        self?.startLoadAndDecodeFutureAssets()
                    }
                    self?.didChangeFrames?(possibleStartTime, timeFromStart)
                }
            )
            assets.append(asset)
        }
    }
    
    deinit {
        didSetupWithParameters = nil
        didChangeFrames = nil
        stopDecode()
    }
    
    func stopDecode() {
        for asset in assets {
            asset.resetDecode()
        }
    }
    
    func startDecodeAt(startTime: Int64) {
        let startIndex = assets.firstIndex(where: { $0.possibleStartTimeInt64 >= startTime }) ?? 0
        if startIndex == currentAssetIndex {
            assets[safe: currentAssetIndex]?.resetDecode()
            assets[safe: currentAssetIndex]?.loadAndStartDecode(timestamp: startTime)
            return
        }
        startDecodeAtIndex(startIndex: startIndex)
    }
    
    func startDecodeAt(startTime: Float) {
        let startIndex = assets.firstIndex(where: { $0.possibleStartTime >= startTime }) ?? 0
        if startIndex == currentAssetIndex {
            let asset = assets[safe: currentAssetIndex]
            asset?.resetDecode()
            let timestamp = Int64(startTime * 10000)
            asset?.loadAndStartDecode(timestamp: timestamp)
            return
        }
        startDecodeAtIndex(startIndex: startIndex)
    }
    
    private func startDecodeAtIndex(startIndex: Int) {
        stopDecode()
        if startIndex >= 0 && startIndex < assets.count {
            currentAssetIndex = startIndex - 1
        } else {
            currentAssetIndex = -1
        }
        startDecodeNextAsset()
    }
    
    private func startDecodeNextAsset() {
        assets[safe: currentAssetIndex]?.resetDecode()
        currentAssetIndex += 1
        assets[safe: currentAssetIndex]?.loadAndStartDecode(timestamp: nil)
    }
    
    private func startLoadAndDecodeFutureAssets() {
        let startIndex = currentAssetIndex + 1
        let endIndex = startIndex + numberOfAssetsToKeepInMemory
        for assetIndex in startIndex..<endIndex {
            if let asset = assets[safe: assetIndex] {
                if !asset.isReady() {
                    asset.loadAndStartDecode(timestamp: nil)
                }
            }
        }
    }
}

extension HLSVideoAssetBuffer {
    func requestVideoFrame(videoFrame: inout HLSVideoAsset.Frame<CVPixelBuffer>?) -> Bool {
        let asset = assets[safe: currentAssetIndex]
        defer {
            asset?.requestVideoFrame(videoFrame: &videoFrame)
        }
        return asset?.isReady() == true
    }
    
    func requestAudioFrame(audioFrame: inout HLSVideoAsset.Frame<AVAudioPCMBuffer>?, for time: CMTime) -> Bool {
        let asset = assets[safe: currentAssetIndex]
        defer {
            asset?.requestAudioFrame(audioFrame: &audioFrame, for: time)
        }
        return asset?.isReady() == true
    }
}

private extension Array {
    subscript(safe index: Index) -> Element? {
        if index >= 0 && index < count {
            return self[index]
        }
        return nil
    }
}
