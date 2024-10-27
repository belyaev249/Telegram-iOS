import AVFoundation

protocol OutputTransport: AnyObject {
    func getVideoOutput() -> HLSVideoAsset.Frame<CVPixelBuffer>?
    func getAudioOutput() -> HLSVideoAsset.Frame<AVAudioPCMBuffer>?
    func setAudio(time: CMTime, position: Int64)
    func setVideo(time: CMTime, position: Int64)
}

struct Timebase {
    static let defaultValue = Timebase(num: 1, den: 1)
    public let num: Int32
    public let den: Int32
    func getPosition(from seconds: TimeInterval) -> Int64 { Int64(seconds * TimeInterval(den) / TimeInterval(num)) }
    func cmtime(for timestamp: Int64) -> CMTime { CMTime(value: timestamp * Int64(num), timescale: den) }
}

struct Clock {
    private var lastMediaTime = CACurrentMediaTime()
    var position = Int64(0)
    var time = CMTime.zero {
        didSet {
            lastMediaTime = CACurrentMediaTime()
        }
    }
    
    func getTime() -> TimeInterval {
        time.seconds + CACurrentMediaTime() - lastMediaTime
    }
}

final class Atomic<T> {
    private let lock = NSLock()
    private(set) var value: T
    
    init(value: T) {
        self.value = value
    }
    
    func getMutable<V>(_ v: @escaping (inout T) -> V) -> V {
        lock.lock()
        defer { lock.unlock() }
        return v(&value)
    }
}

final class QueueLinkedList<T> {
    var head: Node?
    var tail: Node?
    var count: Int = 0
    var totalPush: Int = 0
    var totalPop: Int = 0
    
    init(head: Node? = nil) {
        self.head = head
        self.tail = head
    }
}

extension QueueLinkedList {
    final class Node {
        var value: T
        var next: Node?
        init(value: T) {
            self.value = value
        }
    }
}

extension QueueLinkedList {
    func pop() -> T? {
        if self.head != nil {
            self.count -= 1
            self.totalPop += 1
        }
        let head = head?.next
        self.head = head
        return head?.value
    }
    
    func pop(while condition: (T) -> Bool) -> T? {
        while let node = pop() {
            if !condition(node) {
                return node
            }
        }
        return nil
    }
    
    func push(_ value: T) {
        self.count += 1
        self.totalPush += 1
        let node = Node(value: value)
        
        guard
            self.head != nil,
            self.tail != nil
        else {
            self.head = node
            self.tail = node
            return
        }
        
        tail?.next = node
        tail = node
    }
    
    func forEach(_ v: @escaping (T?) throws -> Void) rethrows {
        if head == nil {
            return
        }
        var node = head
        try v(node?.value)
        while let nextNode = node?.next {
            try v(nextNode.value)
            node = nextNode
        }
    }
    
    func first() -> T? {
        head?.value
    }
    
    func last() -> T? {
        tail?.value
    }
    
    func drop() {
        tail = nil
        head = nil
        count = 0
        totalPush = 0
        totalPop = 0
    }
}

