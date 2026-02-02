import Foundation
import Network

/// Monitors network connectivity status
class NetworkMonitor: ObservableObject {
    static let shared = NetworkMonitor()
    
    private let monitor = NWPathMonitor()
    private let queue = DispatchQueue(label: "NetworkMonitor")
    
    @Published private(set) var isConnected: Bool = false
    @Published private(set) var connectionType: NWInterface.InterfaceType?
    @Published private(set) var isReady: Bool = false
    private var readyContinuations: [CheckedContinuation<Void, Never>] = []
    
    private init() {
        monitor.pathUpdateHandler = { [weak self] path in
            guard let self else { return }
            DispatchQueue.main.async {
                self.isConnected = (path.status == .satisfied)

                // ✅ pick the interface actually being used
                if path.usesInterfaceType(.wifi) {
                    self.connectionType = .wifi
                } else if path.usesInterfaceType(.wiredEthernet) {
                    self.connectionType = .wiredEthernet
                } else if path.usesInterfaceType(.cellular) {
                    self.connectionType = .cellular
                } else {
                    self.connectionType = nil
                }

                // ✅ mark ready + release any awaiters
                if !self.isReady {
                    self.isReady = true
                    let continuations = self.readyContinuations
                    self.readyContinuations.removeAll()
                    continuations.forEach { $0.resume() }
                }
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
    
    func waitUntilReady() async {
        if isReady { return }
        await withCheckedContinuation { cont in
            readyContinuations.append(cont)
        }
    }
}
