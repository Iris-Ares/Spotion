import CoreServices
import Foundation

/// FSEventStream（FileEvents，latency 1s）+ 自有 2s 尾部去抖。
/// 会话文件被 live 追加会产生事件风暴；去抖后触发的增量 refresh 只有 stat 成本，可承受。
final class FileWatcher: @unchecked Sendable {
    private let paths: [String]
    private let debounce: TimeInterval
    private let onChange: @Sendable () -> Void
    private let queue = DispatchQueue(label: "com.ares.spotion.filewatcher")
    private var stream: FSEventStreamRef?
    private var pending: DispatchWorkItem?

    init(paths: [String], debounce: TimeInterval = 2.0, onChange: @escaping @Sendable () -> Void) {
        self.paths = paths
        self.debounce = debounce
        self.onChange = onChange
    }

    func start() {
        guard stream == nil else { return }
        var context = FSEventStreamContext()
        context.info = Unmanaged.passUnretained(self).toOpaque()

        let callback: FSEventStreamCallback = { _, info, _, _, _, _ in
            guard let info else { return }
            Unmanaged<FileWatcher>.fromOpaque(info).takeUnretainedValue().scheduleChange()
        }

        guard let created = FSEventStreamCreate(
            kCFAllocatorDefault,
            callback,
            &context,
            paths as CFArray,
            FSEventStreamEventId(kFSEventStreamEventIdSinceNow),
            1.0,
            FSEventStreamCreateFlags(kFSEventStreamCreateFlagFileEvents | kFSEventStreamCreateFlagNoDefer)
        ) else {
            NSLog("Spotion: FSEventStreamCreate failed for %@", paths.joined(separator: ", "))
            return
        }
        stream = created
        FSEventStreamSetDispatchQueue(created, queue)
        FSEventStreamStart(created)
    }

    func stop() {
        guard let stream else { return }
        FSEventStreamStop(stream)
        FSEventStreamInvalidate(stream)
        FSEventStreamRelease(stream)
        self.stream = nil
        pending?.cancel()
        pending = nil
    }

    private func scheduleChange() {
        pending?.cancel()
        let item = DispatchWorkItem { [onChange] in onChange() }
        pending = item
        queue.asyncAfter(deadline: .now() + debounce, execute: item)
    }

    deinit { stop() }
}
