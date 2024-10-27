import AVFoundation

final class HLSAudioPresenter {
    private let queue = DispatchQueue(label: String(describing: HLSAudioPresenter.self), qos: .userInitiated)
    private weak var audioOutputTransport: OutputTransport?
    
    private let engine = AVAudioEngine()
    private var sourceNode = AVAudioPlayerNode()
    private var sourceNodeAudioFormat: AVAudioFormat?
    
    private var outputLatency: TimeInterval {
        AVAudioSession.sharedInstance().outputLatency
    }
    
    init(audioOutputTransport: OutputTransport) {
        self.audioOutputTransport = audioOutputTransport
    }
    
    func prepare(audioFormat: AVAudioFormat) {
        if sourceNodeAudioFormat == audioFormat {
            return
        }

        sourceNodeAudioFormat = audioFormat
        try? AVAudioSession.sharedInstance().setPreferredOutputNumberOfChannels(Int(audioFormat.channelCount))
                
        engine.attach(sourceNode)
        engine.connect(sourceNode, to: engine.mainMixerNode, format: audioFormat)
        
        engine.stop()
        engine.reset()
                
        DispatchQueue.main.async { [weak self] in
            self?.play()
        }
    }
        
    func tryStartScheduling() {
        guard let audioFrame = self.audioOutputTransport?.getAudioOutput() else {
            return
        }
        let audioBuffer = audioFrame.buffer
        self.sourceNode.scheduleBuffer(audioBuffer)
    }
    
    func play() {
        if sourceNode.engine == nil { return }
        if !engine.isRunning {
            try? engine.start()
            sourceNode.play()

        }
    }
    
    func pause() {
        if sourceNode.engine == nil { return }
        if engine.isRunning {
            engine.pause()
        }
    }
    
    func stop() {
        sourceNode.stop()
        sourceNode.reset()
        engine.stop()
    }
    
    func flush() {
        stop()
        audioOutputTransport = nil
    }
}
