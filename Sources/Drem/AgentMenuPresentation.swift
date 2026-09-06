import Combine
import Foundation

@MainActor
final class AgentMenuPresentation: ObservableObject {
    @Published private(set) var state: AgentMenuState
    @Published private(set) var errorMessage: String?
    @Published private(set) var isRefreshing = false
    private var cancellables = Set<AnyCancellable>()

    init(monitor: AgentMonitor) {
        state = AgentMenuState(snapshot: monitor.snapshot)
        monitor.$snapshot.map(AgentMenuState.init).removeDuplicates()
            .sink { [weak self] in self?.state = $0 }
            .store(in: &cancellables)
        monitor.$errorMessage.removeDuplicates()
            .sink { [weak self] in self?.errorMessage = $0 }
            .store(in: &cancellables)
        monitor.$isRefreshing.removeDuplicates()
            .sink { [weak self] in self?.isRefreshing = $0 }
            .store(in: &cancellables)
    }
}
