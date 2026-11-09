import CoreServices
import Foundation

public enum WatcherState: Equatable {
    case stopped
    case watching
    case noAccess(String)
    case failed(String)
}

/// Watches the Messages folder with FSEvents. When something changes, it reads
/// only the new rows. A slow fallback timer covers missed events and also
/// retries after Full Disk Access is granted. All callbacks run on the main queue.
public final class MessageWatcher {
    public var onCode: ((String, IncomingMessage) -> Void)?
    public var onStateChange: ((WatcherState) -> Void)?

    /// Ignore messages older than this. Example: a backlog that syncs after the Mac wakes.
    public var maxMessageAge: TimeInterval = 5 * 60

    public private(set) var state: WatcherState = .stopped {
        didSet { if state != oldValue { onStateChange?(state) } }
    }

    private let store: MessageStore
    private var lastRowID: Int64?
    private var stream: FSEventStreamRef?
    private var timer: Timer?

    public init(store: MessageStore = MessageStore()) {
        self.store = store
    }

    deinit { stop() }

    public func start() {
        guard timer == nil else { return }
        lastRowID = nil  // start fresh: never copy codes that arrived while paused
        startStream()
        timer = Timer.scheduledTimer(withTimeInterval: 15, repeats: true) { [weak self] _ in
            self?.check()
        }
        timer?.tolerance = 5
        check()
    }

    public func stop() {
        timer?.invalidate()
        timer = nil
        if let stream {
            FSEventStreamStop(stream)
            FSEventStreamInvalidate(stream)
            FSEventStreamRelease(stream)
        }
        stream = nil
        state = .stopped
    }

    public func check() {
        guard timer != nil else { return }
        do {
            guard let last = lastRowID else {
                lastRowID = try store.maxRowID()
                state = .watching
                return
            }
            let messages = try store.messages(after: last)
            var newest: (String, IncomingMessage)?
            for m in messages {
                lastRowID = max(lastRowID ?? 0, m.rowID)
                guard Date().timeIntervalSince(m.date) < maxMessageAge,
                      let code = CodeExtractor.extract(from: m.text) else { continue }
                newest = (code, m)
            }
            state = .watching
            if let (code, m) = newest { onCode?(code, m) }
        } catch let e as MessageStoreError where e.isPermissionError {
            state = .noAccess(e.message)
        } catch {
            state = .failed(error.localizedDescription)
        }
    }

    private func startStream() {
        guard stream == nil else { return }
        var ctx = FSEventStreamContext(
            version: 0,
            info: Unmanaged.passUnretained(self).toOpaque(),
            retain: nil, release: nil, copyDescription: nil
        )
        let callback: FSEventStreamCallback = { _, info, _, _, _, _ in
            guard let info else { return }
            Unmanaged<MessageWatcher>.fromOpaque(info).takeUnretainedValue().check()
        }
        let dir = (store.path as NSString).deletingLastPathComponent
        guard let s = FSEventStreamCreate(
            nil, callback, &ctx, [dir] as CFArray,
            FSEventStreamEventId(kFSEventStreamEventIdSinceNow),
            0.3,
            FSEventStreamCreateFlags(kFSEventStreamCreateFlagNoDefer)
        ) else { return }
        FSEventStreamSetDispatchQueue(s, .main)
        FSEventStreamStart(s)
        stream = s
    }
}
