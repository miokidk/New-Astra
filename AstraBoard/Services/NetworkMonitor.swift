import Foundation
import Network

/// Monitors network connectivity status
class NetworkMonitor: ObservableObject {
    static let shared = NetworkMonitor()
    
    private let monitor = NWPathMonitor()
    private let queue = DispatchQueue(label: "NetworkMonitor")
    
    @Published private(set) var isConnected: Bool = false
    @Published private(set) var connectionType: NWInterface.InterfaceType?
    
    private init() {
        monitor.pathUpdateHandler = { [weak self] path in
            DispatchQueue.main.async {
                self?.isConnected = path.status == .satisfied
                self?.connectionType = path.availableInterfaces.first?.type
            }
        }
        monitor.start(queue: queue)
    }
    
    deinit {
        monitor.cancel()
    }
    
    /// Returns a human-readable connection status
    var connectionDescription: String {
        guard isConnected else {
            return "No internet connection"
        }
        
        switch connectionType {
        case .wifi:
            return "Connected via Wi-Fi"
        case .cellular:
            return "Connected via Cellular"
        case .wiredEthernet:
            return "Connected via Ethernet"
        default:
            return "Connected"
        }
    }
}
