import DremCore
import Foundation

@MainActor
final class AgentMonitor: ObservableObject {
    @Published private(set) var snapshot = AgentSnapshot.empty
    @Published private(set) var errorMessage: String?
    @Published private(set) var isRefreshing = false

    private let engine = LiveActivityEngine()
    private var recoveryTask: Task<Void, Never>?
    private var livenessTask: Task<Void, Never>?
    private var eventTask: Task<Void, Never>?
    private var watcher: FileSystemEventWatcher?
    private var processSources: [Int32: DispatchSourceProcess] = [:]
    private var pendingPaths = Set<String>()
    private var hasStarted = false

    init() {
        Task { @MainActor [weak self] in
            self?.start()
        }
    }

    deinit {
        recoveryTask?.cancel()
        livenessTask?.cancel()
        eventTask?.cancel()
        watcher?.stop()
        processSources.values.forEach { $0.cancel() }
    }

    func start() {
        guard !hasStarted else { return }
        hasStarted = true

        startFileWatcher()

        recoveryTask = Task { [weak self] in
            await self?.refresh()
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 300_000_000_000)
                guard !Task.isCancelled else { break }
                await self?.refresh()
            }
        }

        livenessTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 15_000_000_000)
                guard !Task.isCancelled else { break }
                await self?.removeExitedProcesses()
            }
        }
    }

    func refresh() async {
        guard !isRefreshing else { return }
        isRefreshing = true

        do {
            let state = try await engine.reconcile()
            apply(state)
            errorMessage = nil
        } catch {
            errorMessage = error.localizedDescription
        }

        isRefreshing = false
    }

    private func startFileWatcher() {
        let home = FileManager.default.homeDirectoryForCurrentUser
        let hookStore = HookStateStore(homeDirectory: home)
        let hookDirectory = hookStore.directoryURL
        try? FileManager.default.createDirectory(
            at: hookDirectory,
            withIntermediateDirectories: true
        )

        let candidates = hookStore.observedDirectoryURLs.map(\.path) + [
            home.appendingPathComponent(".codex/sessions", isDirectory: true).path,
            home.appendingPathComponent(".claude/projects", isDirectory: true).path,
            home.appendingPathComponent(".claude/sessions", isDirectory: true).path
        ]
        let paths = candidates.filter { FileManager.default.fileExists(atPath: $0) }

        let watcher = FileSystemEventWatcher(paths: paths) { [weak self] paths in
            Task { @MainActor [weak self] in
                self?.enqueue(paths: paths)
            }
        }
        if !watcher.start() {
            errorMessage = "Не удалось включить событийное наблюдение"
        }
        self.watcher = watcher
    }

    private func enqueue(paths: [String]) {
        pendingPaths.formUnion(paths)
        guard eventTask == nil else { return }
        eventTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 100_000_000)
            guard !Task.isCancelled else { return }
            self?.eventTask = nil
            await self?.consumePendingEvents()
        }
    }

    private func consumePendingEvents() async {
        let paths = Array(pendingPaths)
        pendingPaths.removeAll(keepingCapacity: true)
        guard !paths.isEmpty else { return }

        let state = await engine.handleFileEvents(paths)
        apply(state)

        if state.needsProcessReconciliation && !isRefreshing {
            await refresh()
        }
    }

    private func apply(_ state: LiveActivityState) {
        snapshot = state.snapshot
        watcher?.setTrackedFiles(state.transcriptPaths)
        syncProcessSources(with: state.processIDs)
    }

    private func syncProcessSources(with processIDs: [Int32]) {
        let wanted = Set(processIDs)

        let obsolete = processSources.keys.filter { !wanted.contains($0) }
        for processID in obsolete {
            processSources.removeValue(forKey: processID)?.cancel()
        }

        for processID in wanted where processSources[processID] == nil {
            let source = DispatchSource.makeProcessSource(
                identifier: processID,
                eventMask: .exit,
                queue: .main
            )
            source.setEventHandler { [weak self] in
                Task { @MainActor [weak self] in
                    guard let self else { return }
                    let state = await self.engine.processExited(processID)
                    self.apply(state)
                }
            }
            processSources[processID] = source
            source.resume()
        }
    }

    private func removeExitedProcesses() async {
        let exitedProcessIDs = processSources.keys.filter {
            !ProcessLiveness.isAlive($0)
        }

        for processID in exitedProcessIDs {
            processSources.removeValue(forKey: processID)?.cancel()
            let state = await engine.processExited(processID)
            apply(state)
        }

        let state = await engine.recheckTrackedTranscripts()
        apply(state)
    }
}
