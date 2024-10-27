import AVFoundation
import FFMpegBinding

private let MIN_NUMBER_OF_FRAMES_TO_DECODE = 16

final class HLSAudioFrameConverter {
    private final class AudioFrameSlice {
        private let audioFormat: AVAudioFormat
        private let dataSize: Int
        
        let timestamp: Int64
        let duration: Int64
        let position: Int64
        let timebase: Timebase
        let numberOfSamples: UInt32
        var data: [UnsafeMutablePointer<UInt8>]
        
        init(
            frame: FFMpegAVFrame,
            dataSize: Int,
            audioFormat: AVAudioFormat,
            timebase: Timebase,
            timestamp: Int64,
            duration: Int64,
            position: Int64,
            numberOfSamples: UInt32
        ) {
            self.dataSize = dataSize
            self.audioFormat = audioFormat
            self.timebase = timebase
            self.timestamp = timestamp
            self.position = position
            self.duration = duration
            self.numberOfSamples = numberOfSamples
            let count = audioFormat.isInterleaved ? 1 : audioFormat.channelCount
            data = (0 ..< count).map { _ in
                UnsafeMutablePointer<UInt8>.allocate(capacity: dataSize)
            }
            let frameData = [frame.data[0], frame.data[1], frame.data[2], frame.data[3], frame.data[4], frame.data[5], frame.data[6], frame.data[7]]
            for (i, d) in frameData.enumerated() {
                if let d {
                    memcpy(data[i], d, dataSize)
                }
            }
        }
        
        init(frames: [AudioFrameSlice]) {
            audioFormat = frames[0].audioFormat
            timebase = frames[0].timebase
            timestamp = frames[0].timestamp
            position = frames[0].position
            
            var dataSize: Int = 0
            var numberOfSamples: UInt32 = 0
            var duration: Int64 = 0
            
            for frame in frames {
                duration += frame.duration
                dataSize += frame.dataSize
                numberOfSamples += frame.numberOfSamples
            }
            
            self.duration = duration
            self.dataSize = dataSize
            self.numberOfSamples = numberOfSamples
            
            let count = audioFormat.isInterleaved ? 1 : audioFormat.channelCount
            let data = (0 ..< count).map { _ in
                UnsafeMutablePointer<UInt8>.allocate(capacity: dataSize)
            }
            var offset = 0
            for frame in frames {
                for i in 0 ..< data.count {
                    memcpy(data[i].advanced(by: offset), frame.data[i], frame.dataSize)
//                    data[i].advanced(by: offset).initialize(from: frame.data[i], count: frame.dataSize)
                }
                offset += frame.dataSize
            }
            self.data = data
        }
        
        deinit {
            for i in 0 ..< data.count {
                data[i].deinitialize(count: dataSize)
                data[i].deallocate()
            }
            data.removeAll()
        }
        
        func toAVAudioPCMBuffer() -> AVAudioPCMBuffer? {
            guard let pcmBuffer = AVAudioPCMBuffer(pcmFormat: audioFormat, frameCapacity: numberOfSamples) else {
                return nil
            }
            pcmBuffer.frameLength = pcmBuffer.frameCapacity
            for i in 0 ..< min(Int(pcmBuffer.format.channelCount), data.count) {
                switch audioFormat.commonFormat {
                case .pcmFormatInt16:
                    let capacity = dataSize / MemoryLayout<Int16>.size
                    data[i].withMemoryRebound(to: Int16.self, capacity: capacity) { src in
                        pcmBuffer.int16ChannelData?[i].update(from: src, count: capacity)
                    }
                case .pcmFormatInt32:
                    let capacity = dataSize / MemoryLayout<Int32>.size
                    data[i].withMemoryRebound(to: Int32.self, capacity: capacity) { src in
                        pcmBuffer.int32ChannelData?[i].update(from: src, count: capacity)
                    }
                default:
                    let capacity = dataSize / MemoryLayout<Float>.size
                    data[i].withMemoryRebound(to: Float.self, capacity: capacity) { src in
                         pcmBuffer.floatChannelData?[i].update(from: src, count: capacity)
                    }
                    
                }
            }
            return pcmBuffer
        }
    }
    
    private var slices: [AudioFrameSlice]
    
    init() {
        self.slices = []
        self.slices.reserveCapacity(MIN_NUMBER_OF_FRAMES_TO_DECODE)
    }
    
    func flush() {
        self.slices = []
    }
    
    func convertFrame(audioCodecContext: FFMpegAVCodecContext, frame: FFMpegAVFrame, timebase: Timebase, timestamp: Int64, duration: Int64, position: Int64, force: Bool, completion: @escaping (HLSVideoAsset.Frame<AVAudioPCMBuffer>) -> Bool) -> Bool? {
        
        if !force {
            let numberOfChannels = AVAudioSession.sharedInstance().outputNumberOfChannels
            let numberOfSamples = frame.nbSamples
            let sampleRate = frame.sampleRate
            
            guard let audioFormat = AVAudioFormat(standardFormatWithSampleRate: Double(sampleRate), channels: AVAudioChannelCount(numberOfChannels))
            else {
                return nil
            }
            
            let dataSize = swresampleDataSize(Int32(numberOfChannels), frame, audioFormat.sampleFormat, Int32(audioFormat.sampleRate))
            
            let slice = AudioFrameSlice(frame: frame, dataSize: Int(dataSize), audioFormat: audioFormat, timebase: timebase, timestamp: timestamp, duration: duration, position: position, numberOfSamples: UInt32(numberOfSamples))
            slices.append(slice)
        }
    
        if slices.count == MIN_NUMBER_OF_FRAMES_TO_DECODE || force {
            let sliceBuffer = AudioFrameSlice(frames: slices)
            let num = sliceBuffer.numberOfSamples
            let pcmBuffer = sliceBuffer.toAVAudioPCMBuffer()
            if let pcmBuffer/*, num > 0*/ {
                let frame = HLSVideoAsset.Frame<AVAudioPCMBuffer>(
                    buffer: pcmBuffer,
                    timebase: sliceBuffer.timebase,
                    timestamp: sliceBuffer.timestamp,
                    position: sliceBuffer.position,
                    duration: sliceBuffer.duration,
                    numberOfSamples: num
                )
                slices = []
                return completion(frame)
            }
            slices = []
        }
        
        return true
    }
}

extension AVAudioFormat {
    var sampleFormat: FFMpegAVSampleFormat {
        switch commonFormat {
        case .pcmFormatFloat32:
            return isInterleaved ? FFMPEG_AV_SAMPLE_FMT_FLT : FFMPEG_AV_SAMPLE_FMT_FLTP
        case .pcmFormatFloat64:
            return isInterleaved ? FFMPEG_AV_SAMPLE_FMT_DBL : FFMPEG_AV_SAMPLE_FMT_DBLP
        case .pcmFormatInt16:
            return isInterleaved ? FFMPEG_AV_SAMPLE_FMT_S16 : FFMPEG_AV_SAMPLE_FMT_S16P
        case .pcmFormatInt32:
            return isInterleaved ? FFMPEG_AV_SAMPLE_FMT_S32 : FFMPEG_AV_SAMPLE_FMT_S32P
        case .otherFormat:
            return isInterleaved ? FFMPEG_AV_SAMPLE_FMT_FLT : FFMPEG_AV_SAMPLE_FMT_FLTP
        @unknown default:
            return isInterleaved ? FFMPEG_AV_SAMPLE_FMT_FLT : FFMPEG_AV_SAMPLE_FMT_FLTP
        }
    }
}
//
//extension AVChannelLayout {
//    var layoutTag: AudioChannelLayoutTag? {
//        AudioChannelLayoutTag(self.u.mask)
//    }
//}
