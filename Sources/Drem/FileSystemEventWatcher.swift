import CoreServices
import Darwin
import Foundation

final class FileSystemEventWatcher {
    private let paths: [String]
    private let handler: ([String]) -> Void
    private let queue = DispatchQueue(label: "Drem.FileSystemEvents", qos: .utility)
    private var stream: FSEventStreamRef?
    private struct FileWatch {
        let identity: UInt64
        let source: DispatchSourceFileSystemObject
    }
    private let fileLock = NSLock()
    private var fileWatches: [String: FileWatch] = [:]

    init(paths: [String], handler: @escaping ([String]) -> Void) {
        self.paths = paths
        self.handler = handler
    }

    @discardableResult
    func start() -> Bool {
        guard stream == nil, !paths.isEmpty else { return stream != nil }

        var context = FSEventStreamContext(
            version: 0,
            info: Unmanaged.passUnretained(self).toOpaque(),
            retain: nil,
            release: nil,
            copyDescription: nil
        )
        let flags = FSEventStreamCreateFlags(
            kFSEventStreamCreateFlagFileEvents |
            kFSEventStreamCreateFlagUseCFTypes |
            kFSEventStreamCreateFlagNoDefer
        )

        guard let stream = FSEventStreamCreate(
            kCFAllocatorDefault,
            Self.callback,
            &context,
            paths as CFArray,
            FSEventStreamEventId(kFSEventStreamEventIdSinceNow),
            0.15,
            flags
        ) else { return false }

        self.stream = stream
        FSEventStreamSetDispatchQueue(stream, queue)
        guard FSEventStreamStart(stream) else {
            FSEventStreamInvalidate(stream)
            FSEventStreamRelease(stream)
            self.stream = nil
            return false
        }
        return true
    }

    func stop() {
        setTrackedFiles([])
        if let stream {
            FSEventStreamStop(stream)
            FSEventStreamInvalidate(stream)
            FSEventStreamRelease(stream)
            self.stream = nil
        }
    }

    /// FSEvents is a discovery stream and may delay writes to open files.
    /// Vnode sources deliver writes to known transcripts without polling.
    func setTrackedFiles(_ paths: [String]) {
        fileLock.lock()
        defer { fileLock.unlock() }
        let wanted = Set(paths)
        for path in Array(fileWatches.keys) where !wanted.contains(path) {
            fileWatches.removeValue(forKey: path)?.source.cancel()
        }
        for path in wanted {
            guard let attributes = try? FileManager.default.attributesOfItem(atPath: path),
                  let number = attributes[.systemFileNumber] as? NSNumber else {
                fileWatches.removeValue(forKey: path)?.source.cancel()
                continue
            }
            let identity = number.uint64Value
            if fileWatches[path]?.identity == identity { continue }
            fileWatches.removeValue(forKey: path)?.source.cancel()
            let descriptor = Darwin.open(path, O_EVTONLY | O_CLOEXEC)
            guard descriptor >= 0 else { continue }
            let source = DispatchSource.makeFileSystemObjectSource(
                fileDescriptor: descriptor,
                eventMask: [.write, .extend, .rename, .delete, .revoke],
                queue: queue
            )
            source.setEventHandler { [weak self] in self?.handler([path]) }
            source.setCancelHandler { Darwin.close(descriptor) }
            fileWatches[path] = FileWatch(identity: identity, source: source)
            source.resume()
        }
    }

    deinit {
        stop()
    }

    private func receive(eventPaths: UnsafeMutableRawPointer, count: Int) {
        let array = unsafeBitCast(eventPaths, to: NSArray.self)
        let paths = array.prefix(count).compactMap { $0 as? String }
        if !paths.isEmpty {
            handler(paths)
        }
    }

    private static let callback: FSEventStreamCallback = {
        _, clientInfo, count, eventPaths, _, _ in
        guard let clientInfo else { return }
        let watcher = Unmanaged<FileSystemEventWatcher>
            .fromOpaque(clientInfo)
            .takeUnretainedValue()
        watcher.receive(eventPaths: eventPaths, count: count)
    }
}
