import Foundation
import Network
import Combine

@MainActor
final class NetworkMonitor: ObservableObject {

    @Published private(set) var isConnected: Bool = true
    @Published private(set) var connectionType: ConnectionType = .wifi

    enum ConnectionType {
        case wifi, cellular, ethernet, unknown
    }

    private let monitor = NWPathMonitor()
    private let queue = DispatchQueue(label: "com.portfolioapp.networkmonitor", qos: .utility)

    init() {
        startMonitoring()
    }

    deinit {
        monitor.cancel()
    }

    private func startMonitoring() {
        monitor.pathUpdateHandler = { [weak self] path in
            DispatchQueue.main.async {
                self?.isConnected = path.status == .satisfied
                self?.connectionType = self?.resolveConnectionType(path) ?? .unknown
            }
        }
        monitor.start(queue: queue)
    }

    private func resolveConnectionType(_ path: NWPath) -> ConnectionType {
        if path.usesInterfaceType(.wifi)     { return .wifi }
        if path.usesInterfaceType(.cellular) { return .cellular }
        if path.usesInterfaceType(.wiredEthernet) { return .ethernet }
        return .unknown
    }
}
