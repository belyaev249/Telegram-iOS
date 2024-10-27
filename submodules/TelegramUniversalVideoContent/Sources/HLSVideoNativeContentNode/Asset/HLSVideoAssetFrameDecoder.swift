import AVFoundation
import FFMpegBinding

final class HLSVideoAssetFrameDecoder {
    final class DecodeContext {
        let cancellationToken: HLSVideoAsset.CancellationToken
        var formatContext: FFMpegAVFormatContext
        
        var videoCodecContext: FFMpegAVCodecContext
        var audioCodecContext: FFMpegAVCodecContext
        
        let videoStreamIndex: Int
        let audioStreamIndex: Int
        
        init(
            cancellationToken: HLSVideoAsset.CancellationToken,
            formatContext: FFMpegAVFormatContext,
            videoCodecContext: FFMpegAVCodecContext,
            audioCodecContext: FFMpegAVCodecContext,
            videoStreamIndex: Int,
            audioStreamIndex: Int
        ) {
            self.cancellationToken = cancellationToken
            self.formatContext = formatContext
            self.videoCodecContext = videoCodecContext
            self.audioCodecContext = audioCodecContext
            self.videoStreamIndex = videoStreamIndex
            self.audioStreamIndex = audioStreamIndex
        }
    }
    
    private let videoFrameConverter = HLSVideoFrameConverter()
    private let audioFrameConverter = HLSAudioFrameConverter()
    
    func readFrame(
        decodeContext: DecodeContext,
        completion: @escaping (FramePayload) -> Bool
    ) {
        let formatContext = decodeContext.formatContext
        let videoCodecContext = decodeContext.videoCodecContext
        let audioCodecContext = decodeContext.audioCodecContext
        let videoStreamIndex = decodeContext.videoStreamIndex
        let audioStreamIndex = decodeContext.audioStreamIndex
        let cancellationToken = decodeContext.cancellationToken
        
        let packet = FFMpegPacket()
        let frame = FFMpegAVFrame()
                
    outerLoop:while true {
            var bestEffortTimestamp: Int64 = 0

            let ret1: Bool
            ret1 = formatContext.readFrame(into: packet)
            
            var type: DecodedFrame.DecodedFrameType?
            if packet.streamIndex == videoStreamIndex {
                type = .video
            } else if packet.streamIndex == audioStreamIndex {
                type = .audio
            }
            
            if type == nil {
                continue
            }
            
            let streamContext: FFMpegAVCodecContext
            switch type.unsafelyUnwrapped {
            case .video:
                streamContext = videoCodecContext
            case .audio:
                streamContext = audioCodecContext
            }
            
            let ret2 = packet.send(toDecoder: streamContext)
            if ret2 < 0 { break }
        
            while true {
                let ret3 = streamContext.receive(into: frame)
                packet.unref()
                
                let timebase: Timebase = .defaultValue
                
                var duration = frame.duration
                if duration == 0, frame.sampleRate != 0, timebase.num != 0 {
                    duration = Int64(frame.nbSamples) * Int64(timebase.den) / (Int64(frame.sampleRate) * Int64(timebase.num))
                }
                
                let position = packet.pos
                
                var timestamp = frame.bestEffortTimestamp
                if timestamp < 0 {
                    timestamp = frame.pts
                }
                if timestamp < 0 {
                    timestamp = frame.pktDts
                }
                if timestamp < 0 {
                    timestamp = bestEffortTimestamp
                }
                bestEffortTimestamp = timestamp &+ duration
                
                var isNeedToContinueDecode: Bool?
                
                switch type.unsafelyUnwrapped {
                case .video:
                    isNeedToContinueDecode = videoFrameConverter?.convertFrame(frame: frame) { [cancellationToken] buffer in
                        let frame = HLSVideoAsset.Frame(buffer: buffer, timebase: timebase, timestamp: timestamp, position: position, duration: duration, numberOfSamples: 0)
                        let output = DecodedFrame(type: type.unsafelyUnwrapped, videoFrame: frame, audioFrame: nil)
                        return completion((output, cancellationToken))
                    }
                case .audio:
                    isNeedToContinueDecode = audioFrameConverter.convertFrame(audioCodecContext: audioCodecContext, frame: frame, timebase: timebase, timestamp: timestamp, duration: duration, position: position, force: ret3 != .success) { [cancellationToken] frame in
                        let output = DecodedFrame(type: type.unsafelyUnwrapped, videoFrame: nil, audioFrame: frame)
                        return completion((output, cancellationToken))
                    }
                }
                
                if let isNeedToContinueDecode, !isNeedToContinueDecode {
                    break
                }

                if ret3 == .endOfFrame {
                    break outerLoop
                }
                
                if ret3 != .success {
                    break
                }
                
//                Thread.sleep(forTimeInterval: 1.0/60.0)
            }
            if !ret1 { break }
        }
        
//        av_packet_free(&packet)
//        av_frame_free(&frame)
        
        videoFrameConverter?.flush()
        audioFrameConverter.flush()
    }
}

extension HLSVideoAssetFrameDecoder {
    struct DecodedFrame {
        enum DecodedFrameType {
            case video
            case audio
        }
        let type: DecodedFrameType
        let videoFrame: HLSVideoAsset.Frame<CVPixelBuffer>?
        let audioFrame: HLSVideoAsset.Frame<AVAudioPCMBuffer>?
    }
    
    typealias FramePayload = (DecodedFrame, HLSVideoAsset.CancellationToken)
}
