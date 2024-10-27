import Foundation

enum VoidError: Error {
    case error
}

final class HLSVideoLoader {
    typealias Result<T> = Swift.Result<T, VoidError>
    
    private let queue = DispatchQueue(label: String(describing: HLSVideoLoader.self))
    private let session = URLSession(configuration: .default)
    
    func loadMaster(masterPath: String, c: @escaping (Result<HLSVideoMasterConfigurations>) -> Void) {
        guard let masterUrl = URL(string: masterPath) else {
            c(.failure(.error))
            return
        }
        dataTask(url: masterUrl) { [weak self] masterData in
            guard let masterData, let masterStr = String(data: masterData, encoding: .utf8) else {
                c(.failure(.error))
                return
            }
            let dispathGroup = DispatchGroup()
            var masterConf = HLSVideoMasterConfigurations(path: masterPath, from: masterStr)
            
            for playlistIndex in masterConf.master.indices {
                dispathGroup.enter()
                let playlist = masterConf.master[playlistIndex]
                let playlistPath = playlist.absolutePath
                self?.loadPlaylist(playlistPath: playlistPath) { playlistConfRes in
                    switch playlistConfRes {
                    case .success(let playlistConf):
                        masterConf.master[playlistIndex].configs = playlistConf
                    default:
                        print()
                    }
                    dispathGroup.leave()
                }
            }
            dispathGroup.notify(queue: self?.queue ?? .global()) {
                c(.success(masterConf))
            }
            return
        }
    }
    
    func loadPlaylist(playlistPath: String, c: @escaping (Result<HLSVideoPlaylistConfigurations>) -> Void) {
        guard let playlistUrl = URL(string: playlistPath) else {
            c(.failure(.error))
            return
        }
        dataTask(url: playlistUrl) { playlistData in
            guard let playlistData, let playlistStr = String(data: playlistData, encoding: .utf8) else {
                c(.failure(.error))
                return
            }
            let playlistConf = HLSVideoPlaylistConfigurations(path: playlistPath, from: playlistStr)
            c(.success(playlistConf))
        }
    }
    
    func loadStream(srcPath: String, c: @escaping (Result<URL>) -> Void) {
        guard let sourceUrl = URL(string: srcPath) else {
            c(.failure(.error))
            return
        }
        downloadTask(url: sourceUrl) { urlOrNil in
            guard let destinationUrl = urlOrNil else {
                c(.failure(.error))
                return
            }
            c(.success(destinationUrl))
        }
    }
        
    private func downloadTask(url: URL, c: @escaping (URL?) -> Void) {
        let request = URLRequest(url: url)
        session.downloadTask(with: request) { urlOrNil, _, _ in
            c(urlOrNil)
        }.resume()
    }
    
    private func dataTask(url: URL, c: @escaping (Data?) -> Void) {
        let request = URLRequest(url: url)
        session.dataTask(with: request) { data, _, _ in
            c(data)
        }.resume()
    }
    
    private static var directoryPath: URL? {
        FileManager.default.urls(for: .documentDirectory, in: .allDomainsMask).last
    }
}

struct HLSVideoMasterConfigurations {
    private enum EXT: String, CaseIterable {
        case HEADER = "#EXTM3U"
        case STREAM_INF = "#EXT-X-STREAM-INF:"
    }
    
    private enum EXT_X_STREAM_INF_ATTRIBUTES: String, CaseIterable {
        case AVERAGE_BANDWIDTH = "AVERAGE-BANDWIDTH="
        case BANDWIDTH = "BANDWIDTH="
        case FRAME_RATE = "FRAME-RATE="
        case HDCP_LEVEL = "HDCP-LEVEL="
        case RESOLUTION = "RESOLUTION="
        case VIDEO_RANGE = "VIDEO-RANGE="
        case CODECS = "CODECS="
    }
    
    private let path: String
    private let subpath: String
    
    private(set) var isM3U8: Bool?
    
    struct PlaylistReference {
        var configs: HLSVideoPlaylistConfigurations? = nil
        let averageBanwidth: Int?
        let bandwidth: Int?
        let frameRate: Float?
        let hdcpLevel: String?
        let resolution: (Float?, Float?)?
        let videoRange: String?
        let codecs: [String]?
        
        let relativePath: String
        let absolutePath: String
    }
    
    var master: [PlaylistReference] = []
    
    init(path: String, from str: String) {
        self.path = path
        self.subpath = path.trimmingSuffix(while: { $0 != "/" })
        
        var _attrInf: String?
        for line in str.split(separator: "\n") {
            if line.hasPrefix("#EXT"), let (ext, value) = Self.readExtensionPrefix(String(line)) {
                switch ext {
                case .HEADER:
                    isM3U8 = true
                case .STREAM_INF:
                    _attrInf = value
                }
            } else {
                if let attrInf = _attrInf {
                    let playlist = Self.readPlaylistAttributes(attrInf, String(line), subpath)
                    master.append(playlist)
                    _attrInf = nil
                }
            }
        }
    }
    
    private static func readExtensionPrefix(_ str: String) -> (EXT, String)? {
        for ext in EXT.allCases {
            if let value = str.trailingIfHasPrefix(ext.rawValue) {
                return (ext, value)
            }
        }
        return nil
    }
    
    private static func readPlaylistAttributes(_ attrInf: String, _ relativePath: String, _ subpath: String) -> PlaylistReference {
        var averageBanwidth: Int?
        var bandwidth: Int?
        var frameRate: Float?
        var hdcpLevel: String?
        var resolution: (Float?, Float?)?
        var videoRange: String?
        var codecs: [String]?
        let attributes = attrInf.split(separator: ",")
        for attr in attributes {
            for ext in EXT_X_STREAM_INF_ATTRIBUTES.allCases {
                if let value = String(attr).trailingIfHasPrefix(ext.rawValue) {
                    switch ext {
                    case .AVERAGE_BANDWIDTH:
                        averageBanwidth = Int(value)
                    case .BANDWIDTH:
                        bandwidth = Int(value)
                    case .FRAME_RATE:
                        frameRate = Float(value)
                    case .HDCP_LEVEL:
                        hdcpLevel = value
                    case .RESOLUTION:
                        let res = value.components(separatedBy: [" ", ",", "x", "-"])
                        var w: Float?
                        var h: Float?
                        if res.count > 0 {
                            w = Float(res[0])
                        }
                        if res.count > 1 {
                            h = Float(res[0])
                        }
                        resolution = (w, h)
                    case .VIDEO_RANGE:
                        videoRange = value
                    case .CODECS:
                        codecs = value.components(separatedBy: ",").map { String($0) }
                    }
                }
            }
        }
        let absolutePath = subpath + relativePath
        return PlaylistReference(
            averageBanwidth: averageBanwidth,
            bandwidth: bandwidth,
            frameRate: frameRate,
            hdcpLevel: hdcpLevel,
            resolution: resolution,
            videoRange: videoRange,
            codecs: codecs,
            relativePath: relativePath,
            absolutePath: absolutePath
        )
    }
}

struct HLSVideoPlaylistConfigurations {
    private enum EXT: String, CaseIterable {
        case HEADER = "#EXTM3U"
        case PLAYLIST_TYPE = "#EXT-X-PLAYLIST-TYPE:"
        case TARGET_DURATION = "#EXT-X-TARGETDURATION:"
        case VERSION = "#EXT-X-VERSION:"
        case MEDIA_SEQUENCE = "#EXT-X-MEDIA-SEQUENCE:"
        case INF = "#EXTINF:"
    }
    
    private let path: String
    private let subpath: String
    
    private(set) var isM3U8: Bool?
    private(set) var playlistType: String?
    private(set) var targetDuration: Float?
    private(set) var version: Float?
    private(set) var mediaSequence: Int?
    
    struct MediaReference {
        let info: String
        let index: Int
        
        let duration: Float
        let startTime: Float
        
        let relativePath: String
        let absolutePath: String
    }
    
    private(set) var playlist: [MediaReference] = []
    private(set) var duration: Float = 0.0
    
    init(path: String, from str: String) {
        self.path = path
        self.subpath = path.trimmingSuffix(while: { $0 != "/" })
        
        var _cur_idx = 0
        var _extInf: String?
        for line in str.split(separator: "\n") {
            if line.hasPrefix("#EXT"), let (ext, value) = Self.readExtensionPrefix(String(line)) {
                switch ext {
                case .HEADER:
                    isM3U8 = true
                case .PLAYLIST_TYPE:
                    playlistType = value
                case .TARGET_DURATION:
                    targetDuration = Float(value)
                case .VERSION:
                    version = Float(value)
                case .MEDIA_SEQUENCE:
                    if let int = Int(value) {
                        mediaSequence = int
                        if _cur_idx == 0 {
                            _cur_idx = int
                        }
                    }
                case .INF:
                    _extInf = value
                }
            } else {
                if let extInf = _extInf {
                    _extInf = nil
                    let durationInf = extInf.prefix { ch in
                        ch.isNumber || ch == "."
                    }
                    let duration = Float(durationInf) ?? targetDuration
                    let relativePath = String("partfile514992631203024174.mp4")
                    let absolutePath = subpath + relativePath
                    let media = MediaReference(
                        info: extInf,
                        index: _cur_idx,
                        duration: duration ?? 0,
                        startTime: self.duration,
                        relativePath: relativePath,
                        absolutePath: absolutePath
                    )
                    playlist.append(media)
                    self.duration += media.duration
                    _cur_idx += 1
                }
            }
        }
    }
    
    private static func readExtensionPrefix(_ str: String) -> (EXT, String)? {
        for ext in EXT.allCases {
            if let value = str.trailingIfHasPrefix(ext.rawValue) {
                return (ext, value)
            }
        }
        return nil
    }
}

extension HLSVideoPlaylistConfigurations {
    func findMedia(time: Float) -> MediaReference? {
        var mediaDuration: Float = 1.0
        if let targetDuration, targetDuration != 0 {
            mediaDuration = targetDuration
        }
        let index = Int(time / mediaDuration) + (mediaSequence ?? 0)
        guard let possibleMediaIndex = playlist.firstIndex(where: { $0.index == index }) else {
            return nil
        }
        
        return playlist[possibleMediaIndex]
    }
    
    func findMedia(after: MediaReference) -> MediaReference? {
        let startMediaIndex = playlist.first?.index ?? 0
        let prevMediaIndex = after.index - startMediaIndex
        let possibleMediaIndex = prevMediaIndex + 1
        
        if possibleMediaIndex < playlist.count && possibleMediaIndex >= 0 {
            return playlist[possibleMediaIndex]
        }
        return nil
    }
}

private extension String {
    func trailingIfHasPrefix(_ prefix: String) -> String? {
        if self.hasPrefix(prefix) {
            if #available(iOS 16.0, *) {
                return String(self.trimmingPrefix(prefix))
            } else {
                return self.trimmingPrefix(prefix)
            }
        }
        return nil
    }
    
    
    func trimmingPrefix(_ prefix: String) -> String {
        self.replacingOccurrences(of: prefix, with: "")
    }
    
    func trimmingSuffix(while ch: @escaping (Character) -> Bool) -> String {
        var str = self
        var count = 0
        for character in str.reversed() {
            if ch(character) {
                count += 1
            } else {
                break
            }
        }
        str.removeLast(count)
        return str
    }
}
