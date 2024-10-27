import AVFoundation
import FFMpegBinding
import SwiftSignalKit
import Postbox

struct HLSVideoAssetReference {
    let fileId: Int64
    let lowerBound: Int
    let upperBound: Int
}

final class HLSVideoAsset: AnyObject {
    private let decodeQueue: DispatchQueue
    
    private let source: HLSServerSource
    private var sourceDisposable: Disposable?
    
    private var cancellationToken: Atomic<CancellationToken>
    private var decodeContext: HLSVideoAssetFrameDecoder.DecodeContext?
    private let frameDecoder: HLSVideoAssetFrameDecoder
    
    private let urlSession: URLSession
    private let assetReference: HLSVideoAssetReference
    
    private var assetTempFile: String?
    private var assetSize: Int32?
    
    private lazy var videoFramePool: Atomic<QueueLinkedList<Frame<CVPixelBuffer>>> = .init(value: .init())
    private lazy var audioFramePool: Atomic<QueueLinkedList<Frame<AVAudioPCMBuffer>>> = .init(value: .init())
    
    private(set) var startTime: Int64?
    private(set) var frameRate: Int32?
    private(set) var duration: Int64?
    private(set) var audioFormat: AVAudioFormat?
    
    let possibleStartTime: Float = 0.0
    let possibleFrameRate: Int32
    
    var possibleStartTimeInt64: Int64 {
        let fr = Int64(frameRate ?? 30)
        return Int64(possibleStartTime * 100) * fr * fr
    }
    
    private var isAlreadyDecoding = false
    private var isDecoded = false
    
    private var isIdle = Atomic(value: true)
    private var isLoading = true
    
    private var didSetupWithParameters: ((_ frameRate: Int32?, _ startTime: Int64?, _ duration: Int64?, _ audioFormat: AVAudioFormat?) -> Void)?
    private var didCompleteDecoding: (() -> Void)?
    private var didChangeFrames: ((_ time: CMTime?, _ startTime: Int64?, _ possibleStartTime: Int64?, _ progressOfDecode: Double, _ isLastFrame: Bool) -> Void)?
    
    init(
        source: HLSServerSource,
        frameDecoder: HLSVideoAssetFrameDecoder = .init(),
        urlSession: URLSession = .shared,
        assetReference: HLSVideoAssetReference,
        possibleFrameRate: Int32 = 0,
        decodeQueue: DispatchQueue,
        didSetupWithParameters: ((_ frameRate: Int32?, _ startTime: Int64?, _ duration: Int64?, _ audioFormat: AVAudioFormat?) -> Void)? = nil,
        didCompleteDecoding: (() -> Void)? = nil,
        didChangeFrames: ((_ time: CMTime?, _ startTime: Int64?, _ possibleStartTime: Int64?, _ progressOfDecode: Double, _ isLastFrame: Bool) -> Void)? = nil
    ) {
        self.source = source
        
        let cancellationToken = CancellationToken.new()
        self.cancellationToken = Atomic(value: cancellationToken)
        self.frameDecoder = frameDecoder
        self.urlSession = urlSession
        self.assetReference = assetReference
        self.decodeQueue = decodeQueue
        self.duration = Int64(assetReference.upperBound-assetReference.lowerBound)
        
        self.possibleFrameRate = possibleFrameRate
        
        self.didSetupWithParameters = didSetupWithParameters
        self.didCompleteDecoding = didCompleteDecoding
        self.didChangeFrames = didChangeFrames
    }
    
    deinit {
        didCompleteDecoding = nil
        didChangeFrames = nil
        resetDecode()
    }
    
    func isReady() -> Bool {
        !isIdle.getMutable({ $0 }) && !isLoading
    }
    
    func requestVideoFrame(videoFrame: inout HLSVideoAsset.Frame<CVPixelBuffer>?) {
        if isIdle.getMutable({ $0 }) { return }
        videoFrame = videoFramePool.getMutable({ [weak self] in
            let frame = $0.pop()
            if let time = frame?.cmtime {
                let count = $0.count
                let isLastFrame = count <= 1 && self?.isDecoded == true
                let num = $0.totalPop
                var den = $0.totalPush
                if den == 0 {
                    den = 1
                }
                var progress = Double(num)/Double(den)
                if self?.isDecoded == false {
                    progress = 0.0
                }
                self?.didChangeFrames?(time, self?.startTime, self?.possibleStartTimeInt64, progress, isLastFrame)
            } else if self?.isDecoded == true {
                self?.didChangeFrames?(nil, nil, nil, 0.0, true)
            }
            return frame
        })
    }
    
    func requestAudioFrame(audioFrame: inout HLSVideoAsset.Frame<AVAudioPCMBuffer>?, for time: CMTime) {
        if isIdle.getMutable({ $0 }) { return }
        audioFrame = audioFramePool.getMutable({ pool in
            return pool.pop(while: {
                return $0.cmtime.seconds < time.seconds
            })
        })
    }
    
    func resetDecode() {
        cancellationToken.getMutable({ $0 = .new() })
        
        isIdle.getMutable({ $0 = true })
        isAlreadyDecoding = false
        isDecoded = false
        isLoading = true
        
        videoFramePool = .init(value: .init())
        audioFramePool = .init(value: .init())
    }
    
    func loadAndStartDecode(timestamp: Int64?) {
        let isIdle = isIdle.getMutable({ $0 })
        if isIdle == false { return }
        self.isIdle.getMutable({ $0 = false })
        
        let r = { [weak self] in
            self?.isIdle.getMutable({ $0 = true })
            self?.isLoading = false
        }
        
        let cancellationToken = cancellationToken.getMutable({ $0 })
        
        if let assetTempFile, let assetSize {
            self.isLoading = false
            self.setupAndStartDecode(url: assetTempFile, size: assetSize, timestamp: timestamp, cancellationToken: cancellationToken)
            return
        }
        
        let id = assetReference.fileId
        let range = assetReference.lowerBound..<assetReference.upperBound
        
        sourceDisposable = source.fileData(id: id, range: range).start(next: {[weak self, cancellationToken] res in
            guard let self, let res else {
                return r()
            }
            if self.cancellationToken.getMutable({ $0 }) != cancellationToken {
                return r()
            }
            self.isLoading = false
            self.setupAndStartDecode(url: res.0.path, size: Int32(res.2), timestamp: timestamp, cancellationToken: cancellationToken)
        })
    }
    
    private func setupAndStartDecode(url: String, size: Int32, timestamp: Int64?, cancellationToken: CancellationToken) {
        let res = setup(url: url, size: size, timestamp: timestamp, cancellationToken: cancellationToken, decodeContext: &decodeContext)
        if let res, decodeContext != nil {
            self.assetTempFile = url
            self.assetSize = size
            (self.startTime, self.frameRate, self.audioFormat) = res
            if self.frameRate == nil {
                self.frameRate = self.possibleFrameRate
            }
            didSetupWithParameters?(self.frameRate, self.startTime, self.duration, self.audioFormat)
        } else {
            self.isDecoded = true
            return
        }
        
        if isIdle.getMutable({ $0 }) || isLoading { return }
        startDecode()
    }
    
    private func startDecode() {
        if isAlreadyDecoding {  return }
        isAlreadyDecoding = true
        
        autoreleasepool {
            decodeQueue.async { [weak self] in
                guard let decodeContext = self?.decodeContext else {
                    return
                }
                
                self?.frameDecoder.readFrame(
                    decodeContext: decodeContext,
                    completion: { (output, token) in
                        if self?.cancellationToken.getMutable({ $0 == token }) == true {
                            switch output.type {
                            case .video:
                                self?.videoFramePool.getMutable { $0.push(output.videoFrame.unsafelyUnwrapped) }
                            case .audio:
                                self?.audioFramePool.getMutable { $0.push(output.audioFrame.unsafelyUnwrapped) }
                            }
                            return true
                        } else {
                            return false
                        }
                    }
                )
                
                self?.isDecoded = true
                self?.isAlreadyDecoding = false
                self?.didCompleteDecoding?()
            }
        }
    }
}

private extension HLSVideoAsset {
    func setup(
        url: String,
        size: Int32,
        timestamp: Int64?,
        cancellationToken: CancellationToken,
        decodeContext: inout HLSVideoAssetFrameDecoder.DecodeContext?
    ) -> (startTime: Int64, frameRate: Int32, audioFormat: AVAudioFormat?)? {
        
        let formatContext = FFMpegAVFormatContext()
        
        if !formatContext.openInput(url) {
            return nil
        }

        if !formatContext.findStreamInfo() {
            return nil
        }
        
        let videoStreamIndex = formatContext.findBestStream(FFMpegAVFormatStreamTypeVideo)
        let audioStreamIndex = formatContext.findBestStream(FFMpegAVFormatStreamTypeAudio)
        
        if videoStreamIndex == -1 || audioStreamIndex == -1 {
            return nil
        }
        
        let videoStreamCodecId = formatContext.codecId(atStreamIndex: videoStreamIndex)
        let audioStreamCodecId = formatContext.codecId(atStreamIndex: audioStreamIndex)
        
        let videoStreamCodec = FFMpegAVCodec.find(forId: videoStreamCodecId)
        let audioStreamCodec = FFMpegAVCodec.find(forId: audioStreamCodecId)
                
        if videoStreamCodec == nil || audioStreamCodec == nil {
            return nil
        }
        
        let videoCodecContext = FFMpegAVCodecContext(codec: videoStreamCodec.unsafelyUnwrapped)
        let audioCodecContext = FFMpegAVCodecContext(codec: audioStreamCodec.unsafelyUnwrapped)
        
        formatContext.codecParams(atStreamIndex: videoStreamIndex, to: videoCodecContext)
        formatContext.codecParams(atStreamIndex: audioStreamIndex, to: audioCodecContext)
        
        videoCodecContext.open()
        audioCodecContext.open()
        
//        if let timestamp {
//            _ = timestamp
//            formatContext.seekFrame(forStreamIndex: videoStreamIndex, pts: timestamp, positionOnKeyframe: true)
//            formatContext.seekFrame(forStreamIndex: audioStreamIndex, pts: timestamp, positionOnKeyframe: true)
//        }
        
        let dc =  HLSVideoAssetFrameDecoder.DecodeContext(
            cancellationToken: cancellationToken,
            formatContext: formatContext,
            videoCodecContext: videoCodecContext,
            audioCodecContext: audioCodecContext,
            videoStreamIndex: Int(videoStreamIndex),
            audioStreamIndex: Int(audioStreamIndex)
        )
        
        let startTime = formatContext.startTime(atStreamIndex: videoStreamIndex)
        let fps = formatContext.fps(atStreamIndex: videoStreamIndex)
        let frameRate = Int32(fps.value) / fps.timescale
                
        let audioFormat = AVAudioFormat(
            standardFormatWithSampleRate: Double(audioCodecContext.sampleRate()),
            channels: AVAudioChannelCount(AVAudioSession.sharedInstance().outputNumberOfChannels)
        )
        
        decodeContext = dc
        return (startTime, frameRate, audioFormat)
    }
}

extension HLSVideoAsset {
    typealias CancellationToken = String
}

extension HLSVideoAsset.CancellationToken {
    static func new() -> HLSVideoAsset.CancellationToken {
        UUID().uuidString + "\(Date().timeIntervalSince1970)"
    }
}

extension HLSVideoAsset {
    struct Frame<Buffer> {
        let buffer: Buffer
        
        let timebase: Timebase
        let timestamp: Int64
        let position: Int64
        let duration: Int64
        let numberOfSamples: UInt32
        
        var cmtime: CMTime {
            timebase.cmtime(for: timestamp)
        }
    }
}

private func concatInitAndPartData(initFilePath: String, partFilePath: String) -> Data? {
    if var initData = dataFromTmpFilePath(tmpPath: initFilePath),
       let partData = dataFromTmpFilePath(tmpPath: partFilePath) {
        initData.append(partData)
        return initData
    }
    return nil
}

private func dataFromTmpFilePath(tmpPath: String) -> Data? {
    let filePrefix = "file://"
    var tmpPath = tmpPath
    if !tmpPath.hasPrefix(filePrefix) {
        tmpPath = filePrefix + tmpPath
    }
    
    if let tmpPathUrl = URL(string: tmpPath), let data = try? Data(contentsOf: tmpPathUrl) {
        return data
    }
    return nil
}
