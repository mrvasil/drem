import DremCore
import Foundation

@MainActor
final class AgentMonitor: ObservableObject {
    @Published private(set) var snapshot = AgentSnapshot.empty
    @Published private(set) var errorMessage: String?
    @Published private(set) var isRefreshing = false

    private let engine = LiveActivityEngine()
    private let eventPaths = ActivityEventPaths()
    private var appliedRevision: UInt64 = 0
    private var recoveryTask: Task<Void, Never>?
    private var livenessTask: Task<Void, Never>?
    private var eventTask: Task<Void, Never>?
    private var watcher: FileSystemEventWatcher?
    private var processSources: [Int32: DispatchSourceProcess] = [:]
    private var pendingPaths = Set<String>()
    private var hasStarted = false

    init(startAutomatically: Bool = true) {
        guard startAutomatically else { return }
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
            home.appendingPathComponent(".codex", isDirectory: true).path,
            home.appendingPathComponent(".claude", isDirectory: true).path
        ]
        // Watch the nearest existing parent as well when an agent has not yet
        // created its directories; event routing filters unrelated home writes.
        let paths = Array(Set(candidates.map { path in
            var url = URL(fileURLWithPath: path)
            while !FileManager.default.fileExists(atPath: url.path), url.path != "/" {
                url.deleteLastPathComponent()
            }
            return url.path
        }))

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
        pendingPaths.formUnion(paths.filter(eventPaths.contains))
        guard !pendingPaths.isEmpty, eventTask == nil else { return }
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

    func apply(_ state: LiveActivityState) {
        guard state.revision > appliedRevision else { return }
        appliedRevision = state.revision
        if snapshot.capturedAt == .distantPast || snapshot.statuses != state.snapshot.statuses {
            snapshot = state.snapshot
        }
        watcher?.setTrackedFiles(state.transcriptPaths + state.goalDatabasePaths)
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

        let state = await engine.recheckTrackedTranscripts(validateProcesses: true)
        apply(state)
    }
}
