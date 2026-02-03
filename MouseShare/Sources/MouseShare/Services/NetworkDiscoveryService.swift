import Foundation
import Network

// MARK: - Network Discovery Delegate

protocol NetworkDiscoveryDelegate: AnyObject {
    func networkDiscovery(_ service: NetworkDiscoveryService, didDiscover peer: Peer)
    func networkDiscovery(_ service: NetworkDiscoveryService, didLose peerId: UUID)
    func networkDiscovery(_ service: NetworkDiscoveryService, didUpdatePeer peer: Peer)
}

// MARK: - Network Discovery Service

/// Discovers MouseShare peers on the local network using Bonjour
final class NetworkDiscoveryService {
    
    // MARK: - Properties
    
    weak var delegate: NetworkDiscoveryDelegate?
    
    private var listener: NWListener?
    private var browser: NWBrowser?
    private var isRunning = false
    
    // Local peer info
    private let localPeerId: UUID
    private let localPeerName: String
    private var localScreenWidth: Int
    private var localScreenHeight: Int
    
    // Discovered peers
    private var discoveredPeers: [UUID: Peer] = [:]
    private let peersQueue = DispatchQueue(label: "com.mouseshare.peers", attributes: .concurrent)
    
    // Service configuration
    private let serviceType = "_mouseshare._tcp"
    private let serviceDomain = "local."
    static let defaultPort: UInt16 = 24801
    
    // MARK: - Initialization
    
    init(peerId: UUID, peerName: String, screenWidth: Int, screenHeight: Int) {
        self.localPeerId = peerId
        self.localPeerName = peerName
        self.localScreenWidth = screenWidth
        self.localScreenHeight = screenHeight
    }
    
    deinit {
        stop()
    }
    
    // MARK: - Public Methods
    
    /// Start advertising and browsing for peers
    func start() -> Bool {
        guard !isRunning else { return true }
        
        let advertiseSuccess = startAdvertising()
        let browseSuccess = startBrowsing()
        
        isRunning = advertiseSuccess && browseSuccess
        return isRunning
    }
    
    /// Stop all network discovery
    func stop() {
        stopAdvertising()
        stopBrowsing()
        isRunning = false
    }
    
    /// Update screen dimensions (e.g., after display change)
    func updateScreenDimensions(width: Int, height: Int) {
        self.localScreenWidth = width
        self.localScreenHeight = height
        
        // Restart advertising with new info
        if isRunning {
            stopAdvertising()
            _ = startAdvertising()
        }
    }
    
    /// Get a peer by ID
    func peer(for id: UUID) -> Peer? {
        peersQueue.sync {
            discoveredPeers[id]
        }
    }
    
    /// Get all discovered peers
    var allPeers: [Peer] {
        peersQueue.sync {
            Array(discoveredPeers.values)
        }
    }
    
    // MARK: - Private Methods - Advertising
    
    private func startAdvertising() -> Bool {
        do {
            // Create TXT record with peer info
            let advertisement = PeerAdvertisement(
                id: localPeerId,
                name: localPeerName,
                screenWidth: localScreenWidth,
                screenHeight: localScreenHeight
            )
            
            // Create listener parameters
            let parameters = NWParameters.tcp
            parameters.includePeerToPeer = true
            
            // Create listener
            let listener = try NWListener(using: parameters, on: NWEndpoint.Port(rawValue: Self.defaultPort)!)
            
            // Set service with TXT record
            listener.service = NWListener.Service(
                name: localPeerName,
                type: serviceType,
                domain: serviceDomain,
                txtRecord: advertisement.txtRecord
            )
            
            listener.stateUpdateHandler = { [weak self] state in
                self?.handleListenerState(state)
            }
            
            listener.newConnectionHandler = { [weak self] connection in
                self?.handleIncomingConnection(connection)
            }
            
            listener.start(queue: .main)
            self.listener = listener
            
            print("NetworkDiscoveryService: Started advertising as '\(localPeerName)'")
            return true
            
        } catch {
            print("NetworkDiscoveryService: Failed to start advertising: \(error)")
            return false
        }
    }
    
    private func stopAdvertising() {
        listener?.cancel()
        listener = nil
        print("NetworkDiscoveryService: Stopped advertising")
    }
    
    private func handleListenerState(_ state: NWListener.State) {
        switch state {
        case .ready:
            if let port = listener?.port {
                print("NetworkDiscoveryService: Listener ready on port \(port)")
            }
        case .failed(let error):
            print("NetworkDiscoveryService: Listener failed: \(error)")
            // Try to restart
            stopAdvertising()
            DispatchQueue.main.asyncAfter(deadline: .now() + 2) { [weak self] in
                _ = self?.startAdvertising()
            }
        case .cancelled:
            print("NetworkDiscoveryService: Listener cancelled")
        default:
            break
        }
    }
    
    private func handleIncomingConnection(_ connection: NWConnection) {
        // This is handled by InputServerService
        // Just log it here for debugging
        print("NetworkDiscoveryService: Incoming connection from \(connection.endpoint)")
    }
    
    // MARK: - Private Methods - Browsing
    
    private func startBrowsing() -> Bool {
        let parameters = NWParameters()
        parameters.includePeerToPeer = true
        
        let browser = NWBrowser(for: .bonjour(type: serviceType, domain: serviceDomain), using: parameters)
        
        browser.stateUpdateHandler = { [weak self] state in
            self?.handleBrowserState(state)
        }
        
        browser.browseResultsChangedHandler = { [weak self] results, changes in
            self?.handleBrowseResults(results, changes: changes)
        }
        
        browser.start(queue: .main)
        self.browser = browser
        
        print("NetworkDiscoveryService: Started browsing for peers")
        return true
    }
    
    private func stopBrowsing() {
        browser?.cancel()
        browser = nil
        print("NetworkDiscoveryService: Stopped browsing")
    }
    
    private func handleBrowserState(_ state: NWBrowser.State) {
        switch state {
        case .ready:
            print("NetworkDiscoveryService: Browser ready")
        case .failed(let error):
            print("NetworkDiscoveryService: Browser failed: \(error)")
            // Try to restart
            stopBrowsing()
            DispatchQueue.main.asyncAfter(deadline: .now() + 2) { [weak self] in
                _ = self?.startBrowsing()
            }
        case .cancelled:
            print("NetworkDiscoveryService: Browser cancelled")
        default:
            break
        }
    }
    
    private func handleBrowseResults(_ results: Set<NWBrowser.Result>, changes: Set<NWBrowser.Result.Change>) {
        for change in changes {
            switch change {
            case .added(let result):
                handlePeerDiscovered(result)
            case .removed(let result):
                handlePeerLost(result)
            case .changed(old: _, new: let result, flags: _):
                handlePeerUpdated(result)
            case .identical:
                break
            @unknown default:
                break
            }
        }
    }
    
    private func handlePeerDiscovered(_ result: NWBrowser.Result) {
        guard case .service(let name, let type, let domain, _) = result.endpoint else {
            return
        }
        
        // Get TXT record metadata
        var peerId: UUID?
        var screenWidth = 1920
        var screenHeight = 1080
        
        if case .bonjour(let txtRecord) = result.metadata {
            if let idString = txtRecord["id"], let id = UUID(uuidString: idString) {
                peerId = id
            }
            if let widthStr = txtRecord["width"], let width = Int(widthStr) {
                screenWidth = width
            }
            if let heightStr = txtRecord["height"], let height = Int(heightStr) {
                screenHeight = height
            }
        }
        
        // Skip if this is ourselves (check both ID and name)
        if let id = peerId, id == localPeerId {
            return
        }
        if name == localPeerName {
            return
        }
        
        // Use the peer ID from TXT record, or generate a deterministic ID from name
        // This prevents duplicate entries when TXT record parsing fails
        let id: UUID
        if let existingId = peerId {
            id = existingId
        } else {
            // Generate deterministic UUID from name to prevent duplicates
            id = UUID(uuidString: UUID(uuid: name.utf8.withContiguousStorageIfAvailable { buffer in
                var uuid = UUID().uuid
                for (i, byte) in buffer.prefix(16).enumerated() {
                    withUnsafeMutableBytes(of: &uuid) { $0[i] = byte }
                }
                return uuid
            } ?? UUID().uuid).uuidString) ?? UUID()
        }
        
        // Check if we already have a peer with this name (prevent duplicates from multiple interfaces)
        var existingPeer: Peer?
        peersQueue.sync {
            existingPeer = discoveredPeers.values.first { $0.name == name }
        }
        
        if let existing = existingPeer {
            // Update existing peer instead of adding duplicate
            existing.lastSeen = Date()
            existing.endpoint = result.endpoint  // Update to latest endpoint
            existing.remoteScreenWidth = screenWidth
            existing.remoteScreenHeight = screenHeight
            print("NetworkDiscoveryService: Updated existing peer '\(name)'")
            delegate?.networkDiscovery(self, didUpdatePeer: existing)
            return
        }
        
        // Create new peer
        let peer = Peer(id: id, name: name, hostName: "\(name).\(type)\(domain)")
        peer.endpoint = result.endpoint
        peer.remoteScreenWidth = screenWidth
        peer.remoteScreenHeight = screenHeight
        peer.state = .discovered
        peer.lastSeen = Date()
        
        // Store and notify
        peersQueue.async(flags: .barrier) { [weak self] in
            self?.discoveredPeers[id] = peer
        }
        
        print("NetworkDiscoveryService: Discovered peer '\(name)' (\(id))")
        delegate?.networkDiscovery(self, didDiscover: peer)
    }
    
    private func handlePeerLost(_ result: NWBrowser.Result) {
        guard case .service(let name, _, _, _) = result.endpoint else {
            return
        }
        
        // Find the peer by name and remove
        var lostPeerId: UUID?
        
        peersQueue.sync {
            for (id, peer) in discoveredPeers {
                if peer.name == name {
                    lostPeerId = id
                    break
                }
            }
        }
        
        if let id = lostPeerId {
            peersQueue.async(flags: .barrier) { [weak self] in
                self?.discoveredPeers.removeValue(forKey: id)
            }
            
            print("NetworkDiscoveryService: Lost peer '\(name)' (\(id))")
            delegate?.networkDiscovery(self, didLose: id)
        }
    }
    
    private func handlePeerUpdated(_ result: NWBrowser.Result) {
        guard case .service(let name, _, _, _) = result.endpoint else {
            return
        }
        
        // Find and update the peer
        var updatedPeer: Peer?
        
        peersQueue.sync {
            for (_, peer) in discoveredPeers {
                if peer.name == name {
                    peer.lastSeen = Date()
                    peer.endpoint = result.endpoint
                    
                    // Update metadata if available
                    if case .bonjour(let txtRecord) = result.metadata {
                        if let widthStr = txtRecord["width"], let width = Int(widthStr) {
                            peer.remoteScreenWidth = width
                        }
                        if let heightStr = txtRecord["height"], let height = Int(heightStr) {
                            peer.remoteScreenHeight = height
                        }
                    }
                    
                    updatedPeer = peer
                    break
                }
            }
        }
        
        if let peer = updatedPeer {
            print("NetworkDiscoveryService: Updated peer '\(name)'")
            delegate?.networkDiscovery(self, didUpdatePeer: peer)
        }
    }
}
