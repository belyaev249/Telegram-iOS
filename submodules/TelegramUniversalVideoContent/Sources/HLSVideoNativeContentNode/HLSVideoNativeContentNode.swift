import Foundation
import SwiftSignalKit
import UniversalMediaPlayer
import Postbox
import TelegramCore
import AsyncDisplayKit
import AccountContext
import TelegramAudio
import RangeSet
import AVFoundation
import Display
import PhotoResources
import TelegramVoip

extension HLSVideoNativeContentNode: OutputTransport {
    func getVideoOutput() -> HLSVideoAsset.Frame<CVPixelBuffer>? {
        if !isPlaying { return nil }
        var videoFrame: HLSVideoAsset.Frame<CVPixelBuffer>?
        if let assetBuffer {
            let isReady = assetBuffer.requestVideoFrame(videoFrame: &videoFrame)
            self.isBuffering = !isReady
        }
        return videoFrame
    }
    
    func getAudioOutput() -> HLSVideoAsset.Frame<AVAudioPCMBuffer>? {
        if !isPlaying { return nil }
        var audioFrame: HLSVideoAsset.Frame<AVAudioPCMBuffer>?
        if let assetBuffer {
            let isReady = assetBuffer.requestAudioFrame(audioFrame: &audioFrame, for: mainClock().time)
            self.isBuffering = !isReady
        }
        return audioFrame
    }
    
    func setVideo(time: CMTime, position: Int64) {
        videoClock.time = time
        videoClock.position = position
    }
    
    func setAudio(time: CMTime, position: Int64) {
        audioClock.time = time
        audioClock.position = position
    }
        
    @objc func videoFrameDidChange(_ sender: CADisplayLink) {
        if !isPlaying || isLoading { return }
        videoPresenter.draw()
    }
    
    @objc func audioFrameDidChange(_ sender: CADisplayLink) {
        if !isPlaying || isLoading { return }
        audioPresenter.tryStartScheduling()
    }
}

final class HLSVideoNativeContentNode: ASDisplayNode, UniversalVideoContentNode {
    private let postbox: Postbox
    private let userLocation: MediaResourceUserLocation
    private let fileReference: FileMediaReference
    private let intrinsicDimensions: CGSize

    private let audioSessionManager: ManagedAudioSession
    private let audioSessionDisposable = MetaDisposable()
    private var hasAudioSession = false
    
    private let playbackCompletedListeners = Bag<() -> Void>()
    
    private var initializedStatus = false
    private var statusValue = MediaPlayerStatus(generationTimestamp: 0.0, duration: 0.0, dimensions: CGSize(), timestamp: 0.0, baseRate: 1.0, seekId: 0, status: .paused, soundEnabled: true)
    
    private var baseRate: Double = 1.0
    private var seekId: Int = 0
    
    private var isLoading = false {
        didSet {
            if oldValue == isLoading { return }
            updateStatus()
        }
    }
    private var isPlaying = false {
        didSet {
            if oldValue == isPlaying { return }
            updateStatus()
        }
    }
    private var isBuffering = false {
        didSet {
            if oldValue == isBuffering { return }
            updateStatus()
        }
    }
    
    private let approximateDuration: Double
    private var audioFormat: AVAudioFormat? {
        didSet {
            if oldValue == audioFormat { return }
            updateStatus()
        }
    }
    private var frameRate = Int32(30) {
        didSet {
            if oldValue == frameRate { return }
            updateStatus()
        }
    }
    private var volume = 1.0 {
        didSet {
            if oldValue == volume { return }
            updateStatus()
        }
    }
    private var time = Int64(0) {
        didSet {
            if oldValue == time { return }
            updateStatus()
        }
    }
    private var timestamp: Double {
        Double(time) / Double(frameRate)
    }
    private var actualFrameRate: Int {
        Int(baseRate * Double(frameRate))
    }
    
    private let _status = ValuePromise<MediaPlayerStatus>()
    var status: Signal<MediaPlayerStatus, NoError> {
        return self._status.get()
    }
    
    private let _bufferingStatus = Promise<(RangeSet<Int64>, Int64)?>()
    var bufferingStatus: Signal<(RangeSet<Int64>, Int64)?, NoError> {
        return self._bufferingStatus.get()
    }
    
    var isNativePictureInPictureActive: Signal<Bool, NoError> {
        return .single(false)
    }
    
    private let _ready = Promise<Void>()
    var ready: Signal<Void, NoError> {
        return self._ready.get()
    }
    
    private let _preloadCompleted = ValuePromise<Bool>()
    var preloadCompleted: Signal<Bool, NoError> {
        return self._preloadCompleted.get()
    }
    
    private var playerSource: HLSServerSource?
    private var serverDisposable: Disposable?
    
    private let imageNode: TransformImageNode
    
    private var assetBuffer: HLSVideoAssetBuffer?
    private lazy var videoDisplayLink = CADisplayLink(target: self, selector: #selector(videoFrameDidChange))
    private lazy var audioDisplayLink = CADisplayLink(target: self, selector: #selector(audioFrameDidChange))

    private var audioClock = Clock()
    private var videoClock = Clock()
    
    private func mainClock() -> Clock {
        videoClock
    }
    
    private lazy var videoPresenter = HLSVideoPresenter(videoOutputTransport: self)
    private lazy var audioPresenter = HLSAudioPresenter(audioOutputTransport: self)
    
    private var playlistDataDisposable: Disposable?
    
    private var didBecomeActiveObserver: NSObjectProtocol?
    private var willResignActiveObserver: NSObjectProtocol?
        
    private var dimensions: CGSize?
    private let dimensionsPromise = ValuePromise<CGSize>(CGSize())
    
    private var validLayout: (size: CGSize, actualSize: CGSize)?
        
    private var preferredVideoQuality: UniversalVideoContentVideoQuality = .auto
    
    init(accountId: AccountRecordId, postbox: Postbox, audioSessionManager: ManagedAudioSession, userLocation: MediaResourceUserLocation, fileReference: FileMediaReference, streamVideo: Bool, loopVideo: Bool, enableSound: Bool, baseRate: Double, fetchAutomatically: Bool) {
        self.postbox = postbox
        self.fileReference = fileReference
        self.approximateDuration = fileReference.media.duration ?? 0.0
        self.audioSessionManager = audioSessionManager
        self.userLocation = userLocation
        self.baseRate = baseRate
        
        if var dimensions = fileReference.media.dimensions {
            if let thumbnail = fileReference.media.previewRepresentations.first {
                let dimensionsVertical = dimensions.width < dimensions.height
                let thumbnailVertical = thumbnail.dimensions.width < thumbnail.dimensions.height
                if dimensionsVertical != thumbnailVertical {
                    dimensions = PixelDimensions(width: dimensions.height, height: dimensions.width)
                }
            }
            self.dimensions = dimensions.cgSize
        } else {
            self.dimensions = CGSize(width: 128.0, height: 128.0)
        }
        
        self.imageNode = TransformImageNode()
        
        self.intrinsicDimensions = fileReference.media.dimensions?.cgSize ?? CGSize(width: 480.0, height: 320.0)
                
        if let qualitySet = HLSQualitySet(baseFile: fileReference) {
            self.playerSource = HLSServerSource(accountId: accountId.int64, fileId: fileReference.media.fileId.id, postbox: postbox, userLocation: userLocation, playlistFiles: qualitySet.playlistFiles, qualityFiles: qualitySet.qualityFiles)
        }
        
        super.init()

        self.imageNode.setSignal(internalMediaGridMessageVideo(postbox: postbox, userLocation: self.userLocation, videoReference: fileReference) |> map { [weak self] getSize, getData in
            Queue.mainQueue().async {
                if let strongSelf = self, strongSelf.dimensions == nil {
                    if let dimensions = getSize() {
                        strongSelf.dimensions = dimensions
                        strongSelf.dimensionsPromise.set(dimensions)
                        if let validLayout = strongSelf.validLayout {
                            strongSelf.updateLayout(size: validLayout.size, actualSize: validLayout.actualSize, transition: .immediate)
                        }
                    }
                }
            }
            return getData
        })
        
        self.view.addSubview(self.videoPresenter)
        
        self.videoPresenter.frame = CGRect(origin: CGPoint(), size: self.intrinsicDimensions)
        
        self.videoDisplayLink.preferredFramesPerSecond = 24
        self.videoDisplayLink.add(to: RunLoop.main, forMode: RunLoop.Mode.common)
        self.audioDisplayLink.add(to: RunLoop.main, forMode: RunLoop.Mode.common)
        
        self.imageNode.imageUpdated = { [weak self] _ in
            self?._ready.set(.single(Void()))
        }
                
        self._bufferingStatus.set(.single(nil))
        
        if let playerSource = self.playerSource {
            self.serverDisposable = SharedHLSServer.shared.registerPlayer(source: playerSource, completion: { [weak self] in
                Queue.mainQueue().async {
                    guard let self else {
                        return
                    }
                    
                    let assetUrl = "http://127.0.0.1:\(SharedHLSServer.shared.port)/\(playerSource.id)/master.m3u8"
                    #if DEBUG
                    print("HLSVideoAVContentNode: playing \(assetUrl)")
                    #endif
                    
                    self.setupPlayer(assetUrl)
                }
            })
        }
        
        self.didBecomeActiveObserver = NotificationCenter.default.addObserver(forName: UIApplication.willEnterForegroundNotification, object: nil, queue: nil, using: { [weak self] _ in
            _ = self
//            guard let strongSelf = self, let videoPresenter = strongSelf.videoPresenter else {
//                return
//            }
//            strongSelf.videoPresenter = nil
        })
        self.willResignActiveObserver = NotificationCenter.default.addObserver(forName: UIApplication.didEnterBackgroundNotification, object: nil, queue: nil, using: { [weak self] _ in
            _ = self
//            guard let strongSelf = self, let videoPresenter = strongSelf.videoPresenter else {
//                return
//            }
//            strongSelf.videoPresenter = HLSVideoPresenter(...: self)
        })
    }
    
    deinit {
        self.isPlaying = false
        
        self.playlistDataDisposable?.dispose()
        self.audioSessionDisposable.dispose()
        
        self.videoDisplayLink.invalidate()
        self.videoDisplayLink.remove(from: RunLoop.main, forMode: RunLoop.Mode.common)
        
        self.audioDisplayLink.invalidate()
        self.audioDisplayLink.remove(from: RunLoop.main, forMode: RunLoop.Mode.common)
        
        self.assetBuffer?.stopDecode()
        self.assetBuffer = nil
        self.audioFormat = nil
        
        self.audioPresenter.flush()
        
        if let didBecomeActiveObserver = self.didBecomeActiveObserver {
            NotificationCenter.default.removeObserver(didBecomeActiveObserver)
        }
        if let willResignActiveObserver = self.willResignActiveObserver {
            NotificationCenter.default.removeObserver(willResignActiveObserver)
        }
        
        self.serverDisposable?.dispose()
    }
    
    private func setupPlayer(_ assetUrl: String) {
        setVideoQuality(self.preferredVideoQuality)
    }
    
    private func updateStatus() {
        Queue.mainQueue().async { [weak self] in
            guard let self else { return }
            
            let isPlaying = self.isPlaying
            let status: MediaPlayerPlaybackStatus
            if self.isBuffering {
                status = .buffering(initial: false, whilePlaying: isPlaying, progress: 0.0, display: true)
            } else {
                status = isPlaying ? .playing : .paused
            }
            if timestamp.isFinite && !timestamp.isNaN {
            } else {
                time = 0
            }
            
            self.videoDisplayLink.preferredFramesPerSecond = Int(self.frameRate)
            if let audioFormat = self.audioFormat {
                self.audioDisplayLink.preferredFramesPerSecond = Int(audioFormat.sampleRate)
                self.audioPresenter.prepare(audioFormat: audioFormat)
            }
            if self.isPlaying {
                self.audioPresenter.play()
            } else {
                self.audioPresenter.pause()
            }
            
            self.statusValue = MediaPlayerStatus(generationTimestamp: CACurrentMediaTime(), duration: Double(self.approximateDuration), dimensions: CGSize(), timestamp: timestamp, baseRate: self.baseRate, seekId: self.seekId, status: status, soundEnabled: true)
            self._status.set(self.statusValue)
        }
    }
    
    private func performActionAtEnd() {
        for listener in self.playbackCompletedListeners.copyItems() {
            listener()
        }
    }
    
    func updateLayout(size: CGSize, actualSize: CGSize, transition: ContainedViewLayoutTransition) {
        transition.updatePosition(layer: videoPresenter.layer, position: CGPoint(x: size.width / 2.0, y: size.height / 2.0))
        transition.updateTransformScale(layer: videoPresenter.layer, scale: size.width / self.intrinsicDimensions.width)
        
        transition.updateFrame(node: self.imageNode, frame: CGRect(origin: CGPoint(), size: size))
        
        if let dimensions = self.dimensions {
            let imageSize = CGSize(width: floor(dimensions.width / 2.0), height: floor(dimensions.height / 2.0))
            let makeLayout = self.imageNode.asyncLayout()
            let applyLayout = makeLayout(TransformImageArguments(corners: ImageCorners(), imageSize: imageSize, boundingSize: imageSize, intrinsicInsets: UIEdgeInsets(), emptyColor: .clear))
            applyLayout()
        }
    }
    
    func play() {
        if !self.initializedStatus {
            self._status.set(MediaPlayerStatus(generationTimestamp: 0.0, duration: Double(self.approximateDuration), dimensions: CGSize(), timestamp: 0.0, baseRate: self.baseRate, seekId: self.seekId, status: .buffering(initial: true, whilePlaying: true, progress: 0.0, display: true), soundEnabled: true))
        }
        if isLoading { return }
        self.isPlaying = true
        if !self.hasAudioSession {
            if self.volume != 0.0 {
                self.audioSessionDisposable.set(self.audioSessionManager.push(audioSessionType: .play(mixWithOthers: false), activate: { [weak self] _ in
                    guard let self else {
                        return
                    }
                    self.hasAudioSession = true
                    self.isPlaying = true
                }, deactivate: { [weak self] _ in
                    guard let self else {
                        return .complete()
                    }
                    self.hasAudioSession = false
                    
                    return .complete()
                }))
            }
        }
    }
    
    func pause() {
        if isLoading { return }
        self.isPlaying = false
    }
    
    func togglePlayPause() {
        if isLoading { return }
        if isPlaying {
            self.pause()
        } else {
            self.play()
        }
    }
    
    func setSoundEnabled(_ value: Bool) {
        if value {
            if !self.hasAudioSession {
                self.audioSessionDisposable.set(self.audioSessionManager.push(audioSessionType: .play(mixWithOthers: false), activate: { [weak self] _ in
                    self?.hasAudioSession = true
                    self?.volume = 1.0
                }, deactivate: { [weak self] _ in
                    self?.hasAudioSession = false
                    self?.pause()
                    return .complete()
                }))
            }
        } else {
            self.volume = 0.0
            self.hasAudioSession = false
            self.audioSessionDisposable.set(nil)
        }
    }
    
    func seek(_ timestamp: Double) {
//        isPlaying = false
//        assetBuffer?.startDecodeAt(startTime: Float(timestamp))
    }
    
    func playOnceWithSound(playAndRecord: Bool, seek: MediaPlayerSeek, actionAtEnd: MediaPlayerPlayOnceWithSoundActionAtEnd) {
        self.volume = 1.0
        self.play()
    }
    
    func setSoundMuted(soundMuted: Bool) {
        self.volume = soundMuted ? 0.0 : 1.0
    }
    
    func continueWithOverridingAmbientMode(isAmbient: Bool) {
    }
    
    func setForceAudioToSpeaker(_ forceAudioToSpeaker: Bool) {
    }
    
    func continuePlayingWithoutSound(actionAtEnd: MediaPlayerPlayOnceWithSoundActionAtEnd) {
        self.volume = 0.0
        self.hasAudioSession = false
        self.audioSessionDisposable.set(nil)
    }
    
    func setContinuePlayingWithoutSoundOnLostAudioSession(_ value: Bool) {
    }
    
    func setBaseRate(_ baseRate: Double) {
        self.baseRate = baseRate
    }
    
    func setVideoQuality(_ videoQuality: UniversalVideoContentVideoQuality) {
        if self.isLoading { return }
        self.preferredVideoQuality = videoQuality
        
        guard let playerSource = self.playerSource else {
            return
        }
        
        self.isLoading = true
        self.isPlaying = false
        
        assetBuffer?.stopDecode()
        assetBuffer = nil
        
        audioPresenter.stop()
        
        let qualityValue: Int
        switch videoQuality {
        case .auto:
            qualityValue = self.playerSource?.qualityFiles.keys.min() ?? 480
        case let .quality(_qualityValue):
            qualityValue = _qualityValue
        }
        
        playlistDataDisposable = playerSource.playlistData(quality: qualityValue).start(next: { [weak self] playlist in
            guard let self, let playerSource = self.playerSource else { return }
            
            var assetReferences: [HLSVideoAssetReference] = []
            let (fileId, ranges) = Self.parseFileIdAndPartDataRanges(from: playlist)
            if let fileId, let fileIdInt64 = Int64(fileId) {
                for range in ranges {
                    let assetReference = HLSVideoAssetReference(fileId: fileIdInt64, lowerBound: range.lowerBound, upperBound: range.upperBound)
                    assetReferences.append(assetReference)
                }
            }
            
            self.assetBuffer = .init(
                source: playerSource,
                assetReferences: assetReferences,
                numberOfAssetsToKeepInMemory: 1,
                didSetupWithParameters: { [weak self] frameRate, audioFormat in
                    self?.frameRate = frameRate ?? 30
                    self?.audioFormat = audioFormat
                    
                    self?.isLoading = false
                    self?.isPlaying = true
                },
                didChangeFrames: { startTime, timeFromStart in
                    
                }
            )
            self.assetBuffer?.startDecodeAt(startTime: 0.0)
        })
        
    }
    
    func videoQualityState() -> (current: Int, preferred: UniversalVideoContentVideoQuality, available: [Int])? {
        guard let playerSource = self.playerSource else {
            return nil
        }
        let current = 480
        var available: [Int] = Array(playerSource.qualityFiles.keys)
        available.sort(by: { $0 > $1 })
        return (current, self.preferredVideoQuality, available)
    }
    
    func addPlaybackCompleted(_ f: @escaping () -> Void) -> Int {
        return self.playbackCompletedListeners.add(f)
    }
    
    func removePlaybackCompleted(_ index: Int) {
        self.playbackCompletedListeners.remove(index)
    }
    
    func fetchControl(_ control: UniversalVideoNodeFetchControl) {
    }
    
    func notifyPlaybackControlsHidden(_ hidden: Bool) {
    }

    func setCanPlaybackWithoutHierarchy(_ canPlaybackWithoutHierarchy: Bool) {
    }
    
    func enterNativePictureInPicture() -> Bool {
        return false
    }
    
    func exitNativePictureInPicture() {
    }
}

private extension HLSVideoNativeContentNode {
    static func parseFileIdAndPartDataRanges(from playlist: String, by c: Int = -1) -> (uri: String?, ranges: [Range<Int>]) {
        var fileId: String?
        var ranges: [Range<Int>] = []
        print(playlist)
        if let uriInf = playlist.matches(by: #"#EXT-X-MAP:URI=.*\n"#).first {
            if let uri = uriInf.matches(by: #"".*(.mp4)""#).first {
                let filePath = uri.trimmingCharacters(in: [#"""#])
                fileId = String(filePath[filePath.index(filePath.startIndex, offsetBy: "partfile".count) ..< filePath.index(filePath.endIndex, offsetBy: -".mp4".count)])
            }
        }

        var _c = 0
        var _lowerBound = 0
        var _upperBound = 0
        
        for extInf in playlist.matches(by: "#EXTINF:.*(\n)*.*(\n)*.*") {
            if let byterange = extInf.matches(by: "#EXT-X-BYTERANGE:[0-9.]*@[0-9.]*").first,
               let byterangeStr = byterange.matches(by: "[0-9.]*@[0-9.]*").first {
                let lengthAndOffset = byterangeStr.split(separator: "@")
                if lengthAndOffset.count == 2 {
                    if let length = Int(lengthAndOffset[0]), let offset = Int(lengthAndOffset[1]) {
                        _c += 1
                        let lowerBound = _lowerBound
                        let upperBound = offset + length
                        _upperBound = upperBound
                        if c == -1 {
                            if _lowerBound == 0 {
                                _lowerBound = lowerBound
                            }
                        } else if _c == c {
                            let range = lowerBound..<upperBound+1
                            ranges.append(range)
                            _c = 0
                            _lowerBound = upperBound
                        }
                        
                    } else if let prevRange = ranges.last {
                        ranges.append(prevRange)
                    }
                }
            }
        }
        if _c != 0 || c == -1 {
            ranges.append(_lowerBound..<_upperBound+1)
        }
        
        return (fileId, ranges)
    }
}

private extension String {
    func matches(by pattern: String) -> [String] {
        var matched: [String] = []
        if count <= 0 { return matched }
        
        let regex = try? NSRegularExpression(pattern: pattern)
        guard let regex else { return matched }
        
        let matches = regex.matches(in: self, range: NSMakeRange(0, self.count))
        for match in matches {
            if let range = Range(match.range, in: self) {
                matched.append(String(self[range]))
            }
        }
        return matched
    }
}
