import Foundation
import CoreServices

/// Watches the Claude Code transcript folders (~/.claude/projects) with FSEvents and calls
/// `onChange` on the main queue `debounce` seconds after a change. A turn writes many lines, so the
/// debounce makes one call per burst. It reads no file itself.
final class TranscriptWatcher {
    private var stream: FSEventStreamRef?
    private var pending: DispatchWorkItem?
    private let path: String
    private let debounce: Double
    private let onChange: () -> Void

    init(path: String = NSHomeDirectory() + "/.claude/projects", debounce: Double = 5, onChange: @escaping () -> Void) {
        self.path = path; self.debounce = debounce; self.onChange = onChange
    }

    deinit { stop() }

    func start() {
        guard stream == nil else { return }
        var context = FSEventStreamContext(version: 0, info: Unmanaged.passUnretained(self).toOpaque(),
                                           retain: nil, release: nil, copyDescription: nil)
        let callback: FSEventStreamCallback = { _, info, _, _, _, _ in
            guard let info else { return }
            Unmanaged<TranscriptWatcher>.fromOpaque(info).takeUnretainedValue().changed()
        }
        // The folder may not exist yet (Claude Code never ran): watch its parent then.
        let watched = FileManager.default.fileExists(atPath: path) ? path : (path as NSString).deletingLastPathComponent
        guard let s = FSEventStreamCreate(nil, callback, &context, [watched] as CFArray,
                                          FSEventStreamEventId(kFSEventStreamEventIdSinceNow), 1.0,
                                          FSEventStreamCreateFlags(kFSEventStreamCreateFlagNoDefer)) else { return }
        FSEventStreamSetDispatchQueue(s, .main)
        FSEventStreamStart(s)
        stream = s
    }

    func stop() {
        pending?.cancel(); pending = nil
        guard let s = stream else { return }
        FSEventStreamStop(s)
        FSEventStreamInvalidate(s)
        FSEventStreamRelease(s)
        stream = nil
    }

    /// One call `debounce` seconds after the first change of a burst. Not reset by later changes:
    /// other sessions write all the time, and a reset would never let the call happen.
    private func changed() {
        guard pending == nil else { return }
        let work = DispatchWorkItem { [weak self] in self?.pending = nil; self?.onChange() }
        pending = work
        DispatchQueue.main.asyncAfter(deadline: .now() + debounce, execute: work)
    }
}
