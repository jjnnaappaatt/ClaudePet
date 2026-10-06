import Foundation
import CoreServices

/// Watches a directory tree with FSEvents and fires `onChange` (debounced) with **which files
/// changed**, so the scanner can stat those instead of walking ~2,000 transcripts per event.
public final class FileWatcher {
    private let paths: [String]
    private let debounce: TimeInterval
    private let onChange: @Sendable (FileChanges) -> Void

    private var stream: FSEventStreamRef?
    private let queue = DispatchQueue(label: "com.napat.ClaudePet.filewatcher")
    private var pending: DispatchWorkItem?
    /// Accumulated across the debounce window; only touched on `queue`.
    private var accumulated: FileChanges?

    public init(paths: [String], debounce: TimeInterval = 0.25,
                onChange: @escaping @Sendable (FileChanges) -> Void) {
        self.paths = paths
        self.debounce = debounce
        self.onChange = onChange
    }

    public func start() {
        guard stream == nil else { return }

        var context = FSEventStreamContext(
            version: 0,
            info: Unmanaged.passUnretained(self).toOpaque(),
            retain: nil, release: nil, copyDescription: nil
        )

        let callback: FSEventStreamCallback = { _, info, count, eventPaths, eventFlags, _ in
            guard let info else { return }
            // With `UseCFTypes`, `eventPaths` is a CFArray of CFString.
            let paths = unsafeBitCast(eventPaths, to: NSArray.self) as? [String] ?? []
            let flags = (0..<count).map { eventFlags[$0] }
            Unmanaged<FileWatcher>.fromOpaque(info).takeUnretainedValue()
                .schedule(FileWatcher.changes(paths: paths, flags: flags))
        }

        let flags = FSEventStreamCreateFlags(
            kFSEventStreamCreateFlagFileEvents | kFSEventStreamCreateFlagNoDefer
                | kFSEventStreamCreateFlagUseCFTypes
        )
        guard let s = FSEventStreamCreate(
            kCFAllocatorDefault, callback, &context,
            paths as CFArray,
            FSEventStreamEventId(kFSEventStreamEventIdSinceNow),
            0.3, flags
        ) else { return }

        FSEventStreamSetDispatchQueue(s, queue)
        FSEventStreamStart(s)
        stream = s
    }

    public func stop() {
        guard let s = stream else { return }
        FSEventStreamStop(s)
        FSEventStreamInvalidate(s)
        FSEventStreamRelease(s)
        stream = nil
    }

    private func schedule(_ changes: FileChanges) {
        accumulated = accumulated?.merged(with: changes) ?? changes
        pending?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self, let c = self.accumulated else { return }
            self.accumulated = nil
            // Writes that touched no transcript (memory files, editor temp files) need no scan.
            if c == .paths([]) { return }
            self.onChange(c)
        }
        pending = work
        queue.asyncAfter(deadline: .now() + debounce, execute: work)
    }

    /// Which events can be answered by statting the named files, and which need a full walk.
    ///
    /// A walk is needed when FSEvents itself says its paths are incomplete (dropped events, a
    /// coalesced "scan this subtree", the root moving), or when a *directory* was created, moved or
    /// removed — files can appear or vanish beneath it without an event naming each one.
    static func changes(paths: [String], flags: [FSEventStreamEventFlags]) -> FileChanges {
        let rescan = FSEventStreamEventFlags(
            kFSEventStreamEventFlagMustScanSubDirs | kFSEventStreamEventFlagUserDropped
                | kFSEventStreamEventFlagKernelDropped | kFSEventStreamEventFlagRootChanged
                | kFSEventStreamEventFlagEventIdsWrapped)
        let dirShape = FSEventStreamEventFlags(
            kFSEventStreamEventFlagItemCreated | kFSEventStreamEventFlagItemRemoved
                | kFSEventStreamEventFlagItemRenamed)
        var out = Set<String>()
        for (path, flag) in zip(paths, flags) {
            if flag & rescan != 0 { return .everything }
            if flag & FSEventStreamEventFlags(kFSEventStreamEventFlagItemIsDir) != 0 {
                if flag & dirShape != 0 { return .everything }
                continue
            }
            if path.hasSuffix(".jsonl") { out.insert(path) }
        }
        return .paths(out)
    }

    deinit { stop() }
}
