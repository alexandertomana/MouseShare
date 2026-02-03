import Foundation
import Cocoa
import Combine
import Network

// MARK: - Control State

enum ControlState {
    case local          // We have control of our own mouse/keyboard
    case controlling    // We're controlling a remote peer
    case controlled     // A remote peer is controlling us
}

// MARK: - MouseShare Controller

/// Main controller that coordinates all services
@MainActor
final class MouseShareController: ObservableObject {
    
    // MARK: - Published Properties
    
    @Published var isRunning = false
    @Published var controlState: ControlState = .local
    @Published var connectedPeers: [Peer] = []
    @Published var discoveredPeers: [Peer] = []
    @Published var settings: AppSettings
    @Published var hasAccessibilityPermission = false
    @Published var statusMessage = "Not running"
    
    // Currently active peer (controlling or controlled by)
    @Published var activePeer: Peer?
    
    // MARK: - Services
    
    private var eventCaptureService: EventCaptureService?
    private var eventInjectionService: EventInjectionService?
    private var networkDiscoveryService: NetworkDiscoveryService?
    private var inputNetworkService: InputNetworkService?
    private var screenEdgeService: ScreenEdgeService?
    private var clipboardService: ClipboardService?
    
    // MARK: - Properties
    
    let localPeerId: UUID
    let localPeerName: String
    
    private var cancellables = Set<AnyCancellable>()
    
    // Event batching for network efficiency
    private var pendingEvents: [InputEvent] = []
    private var eventBatchTimer: Timer?
    private let eventBatchInterval: TimeInterval = 0.008  // ~120Hz
    
    // Heartbeat for connection monitoring
    private var heartbeatTimer: Timer?
    private let heartbeatInterval: TimeInterval = 1.0
    
    // SAFETY: Failsafe timeout for screen transitions
    // If remote doesn't acknowledge within this time, return to local control
    private var transitionFailsafeTimer: Timer?
    private let transitionFailsafeTimeout: TimeInterval = 2.0
    private var pendingTransitionPeer: Peer?
    private var pendingTransitionEdge: ScreenEdge?
    
    // MARK: - Initialization
    
    init() {
        // Load or generate local peer ID
        if let savedId = UserDefaults.standard.string(forKey: "LocalPeerId"),
           let id = UUID(uuidString: savedId) {
            self.localPeerId = id
        } else {
            self.localPeerId = UUID()
            UserDefaults.standard.set(localPeerId.uuidString, forKey: "LocalPeerId")
        }
        
        // Get computer name
        self.localPeerName = Host.current().localizedName ?? "Mac"
        
        // Load settings
        self.settings = AppSettings.load()
        
        // Check accessibility permission
        self.hasAccessibilityPermission = EventCaptureService.hasAccessibilityPermission
        
        print("MouseShareController: Initialized as '\(localPeerName)' (\(localPeerId))")
        
        // Auto-start after initialization
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 1_000_000_000) // 1 second delay
            if !self.isRunning {
                self.start()
            }
        }
    }
    
    // MARK: - Public Methods
    
    /// Start all services
    func start() {
        guard !isRunning else { return }
        
        // Check accessibility permission
        if !hasAccessibilityPermission {
            hasAccessibilityPermission = EventCaptureService.requestAccessibilityPermission()
            if !hasAccessibilityPermission {
                statusMessage = "Accessibility permission required"
                return
            }
        }
        
        // Get screen info
        let mainDisplay = DisplayInfo.mainDisplay
        let screenWidth = mainDisplay?.width ?? 1920
        let screenHeight = mainDisplay?.height ?? 1080
        
        // Initialize services
        initializeServices(screenWidth: screenWidth, screenHeight: screenHeight)
        
        // Start services
        guard startServices() else {
            statusMessage = "Failed to start services"
            return
        }
        
        // Start heartbeat
        startHeartbeat()
        
        isRunning = true
        statusMessage = "Running"
        
        print("MouseShareController: Started")
    }
    
    /// Stop all services
    func stop() {
        guard isRunning else { return }
        
        stopHeartbeat()
        stopEventBatching()
        stopServices()
        
        isRunning = false
        controlState = .local
        activePeer = nil
        statusMessage = "Stopped"
        
        print("MouseShareController: Stopped")
    }
    
    /// Connect to a peer
    func connect(to peer: Peer) {
        guard isRunning else { return }
        
        peer.state = .connecting
        inputNetworkService?.connect(to: peer)
    }
    
    /// Disconnect from a peer
    func disconnect(from peer: Peer) {
        inputNetworkService?.disconnect(from: peer.id)
        peer.state = .disconnected
        
        if activePeer?.id == peer.id {
            returnToLocalControl()
        }
        
        connectedPeers.removeAll { $0.id == peer.id }
    }
    
    /// Configure screen edge link
    func linkEdge(_ edge: ScreenEdge, to peer: Peer) {
        settings.screenConfig.setLink(edge: edge, peerId: peer.id, peerEdge: edge.opposite)
        settings.save()
        
        print("MouseShareController: Linked \(edge.displayName) edge to \(peer.name)")
    }
    
    /// Remove screen edge link
    func unlinkEdge(_ edge: ScreenEdge) {
        settings.screenConfig.removeLink(edge: edge)
        settings.save()
    }
    
    /// Update settings
    func updateSettings(_ newSettings: AppSettings) {
        settings = newSettings
        settings.save()
        
        // Apply encryption changes
        if settings.encryptionEnabled && !settings.encryptionPassword.isEmpty {
            try? inputNetworkService?.enableEncryption(password: settings.encryptionPassword)
        } else {
            inputNetworkService?.disableEncryption()
        }
        
        // Apply screen edge changes
        screenEdgeService?.edgeThreshold = CGFloat(settings.screenConfig.edgeThreshold)
        screenEdgeService?.transitionDelay = settings.screenConfig.transitionDelay
        screenEdgeService?.cornerDeadZone = CGFloat(settings.screenConfig.cornerDeadZone)
        
        // Apply clipboard sync
        if settings.clipboardSyncEnabled {
            clipboardService?.startMonitoring()
        } else {
            clipboardService?.stopMonitoring()
        }
    }
    
    // MARK: - Private Methods - Initialization
    
    private func initializeServices(screenWidth: Int, screenHeight: Int) {
        // Event capture
        eventCaptureService = EventCaptureService()
        eventCaptureService?.delegate = self
        
        // Event injection
        eventInjectionService = EventInjectionService()
        
        // Network discovery
        networkDiscoveryService = NetworkDiscoveryService(
            peerId: localPeerId,
            peerName: localPeerName,
            screenWidth: screenWidth,
            screenHeight: screenHeight
        )
        networkDiscoveryService?.delegate = self
        
        // Input network
        inputNetworkService = InputNetworkService(
            peerId: localPeerId,
            peerName: localPeerName,
            screenWidth: screenWidth,
            screenHeight: screenHeight
        )
        inputNetworkService?.delegate = self
        
        // Screen edge
        screenEdgeService = ScreenEdgeService()
        screenEdgeService?.delegate = self
        screenEdgeService?.edgeThreshold = CGFloat(settings.screenConfig.edgeThreshold)
        screenEdgeService?.transitionDelay = settings.screenConfig.transitionDelay
        screenEdgeService?.cornerDeadZone = CGFloat(settings.screenConfig.cornerDeadZone)
        
        // Clipboard
        clipboardService = ClipboardService()
        clipboardService?.delegate = self
        
        // Enable encryption if configured
        if settings.encryptionEnabled && !settings.encryptionPassword.isEmpty {
            try? inputNetworkService?.enableEncryption(password: settings.encryptionPassword)
        }
    }
    
    private func startServices() -> Bool {
        // Start event capture
        guard eventCaptureService?.start() == true else {
            print("MouseShareController: Failed to start event capture")
            return false
        }
        
        // Start network discovery
        guard networkDiscoveryService?.start() == true else {
            print("MouseShareController: Failed to start network discovery")
            return false
        }
        
        // Start input network listener
        guard inputNetworkService?.startListening() == true else {
            print("MouseShareController: Failed to start input listener")
            return false
        }
        
        // Start clipboard monitoring if enabled
        if settings.clipboardSyncEnabled {
            clipboardService?.startMonitoring()
        }
        
        return true
    }
    
    private func stopServices() {
        eventCaptureService?.stop()
        networkDiscoveryService?.stop()
        inputNetworkService?.stopListening()
        inputNetworkService?.disconnectAll()
        clipboardService?.stopMonitoring()
        screenEdgeService?.resetTransitionState()
    }
    
    // MARK: - Private Methods - Control State
    
    private func transitionToControlling(peer: Peer, edge: ScreenEdge, position: CGFloat) {
        // SAFETY: Verify connection is alive before transitioning
        guard connectionQueue_isConnectionAlive(for: peer.id) else {
            print("MouseShareController: Cannot transition - connection to \(peer.name) is not alive")
            statusMessage = "Connection lost to \(peer.name)"
            return
        }
        
        controlState = .controlling
        activePeer = peer
        peer.state = .controlling
        
        // Store pending transition info for failsafe
        pendingTransitionPeer = peer
        pendingTransitionEdge = edge
        
        // Tell the capture service to forward events instead of local processing
        eventCaptureService?.setControlling(false)
        
        // Hide local cursor
        eventInjectionService?.setCursorVisible(false)
        
        // Send screen enter event to peer
        let enterEvent = InputEvent.screenEnter(edge: edge.opposite, x: Float(position), y: Float(position))
        inputNetworkService?.send(enterEvent, to: peer.id)
        
        // Start event batching
        startEventBatching(for: peer.id)
        
        // SAFETY: Start failsafe timer - if remote doesn't respond, return to local
        startTransitionFailsafe()
        
        statusMessage = "Controlling \(peer.name)"
        print("MouseShareController: Now controlling \(peer.name)")
        print("MouseShareController: Press Escape to return to local control")
    }
    
    /// Check if a connection to a peer is alive (has an active connection)
    private func connectionQueue_isConnectionAlive(for peerId: UUID) -> Bool {
        // Check if we have an active connection to this peer
        return connectedPeers.contains { $0.id == peerId && $0.state == .connected }
    }
    
    // MARK: - Transition Failsafe
    
    private func startTransitionFailsafe() {
        cancelTransitionFailsafe()
        
        transitionFailsafeTimer = Timer.scheduledTimer(withTimeInterval: transitionFailsafeTimeout, repeats: false) { [weak self] _ in
            Task { @MainActor in
                self?.handleTransitionFailsafe()
            }
        }
    }
    
    private func cancelTransitionFailsafe() {
        transitionFailsafeTimer?.invalidate()
        transitionFailsafeTimer = nil
        pendingTransitionPeer = nil
        pendingTransitionEdge = nil
    }
    
    private func handleTransitionFailsafe() {
        guard controlState == .controlling else {
            cancelTransitionFailsafe()
            return
        }
        
        // Check if we've received any acknowledgment (heartbeat or events)
        // If not, return to local control
        if let peer = pendingTransitionPeer {
            let timeSinceLastSeen = Date().timeIntervalSince(peer.lastSeen)
            
            // If we haven't heard from the peer recently, assume connection is dead
            if timeSinceLastSeen > transitionFailsafeTimeout {
                print("MouseShareController: FAILSAFE - No response from \(peer.name), returning to local control")
                statusMessage = "Lost connection to \(peer.name)"
                returnToLocalControl()
            } else {
                // Connection seems alive, clear the failsafe
                cancelTransitionFailsafe()
            }
        } else {
            // No pending peer info, something is wrong - return to local
            print("MouseShareController: FAILSAFE - Invalid state, returning to local control")
            returnToLocalControl()
        }
    }
    
    private func transitionToControlled(by peer: Peer) {
        controlState = .controlled
        activePeer = peer
        peer.state = .controlled
        
        // Show cursor and prepare for remote input
        eventInjectionService?.setCursorVisible(true)
        eventInjectionService?.setRemoteScreenBounds(
            width: peer.remoteScreenWidth,
            height: peer.remoteScreenHeight
        )
        
        statusMessage = "Controlled by \(peer.name)"
        print("MouseShareController: Now controlled by \(peer.name)")
    }
    
    private func returnToLocalControl() {
        let previousPeer = activePeer
        
        // Cancel any pending failsafe timer
        cancelTransitionFailsafe()
        
        controlState = .local
        activePeer = nil
        
        // Tell capture service to process events locally
        eventCaptureService?.setControlling(true)
        
        // Show cursor
        eventInjectionService?.setCursorVisible(true)
        
        // Stop event batching
        stopEventBatching()
        
        // Reset screen edge state
        screenEdgeService?.resetTransitionState()
        
        if let peer = previousPeer {
            peer.state = .connected
            // Notify the peer we're leaving (if still connected)
            if let edge = pendingTransitionEdge {
                let leaveEvent = InputEvent.screenLeave(edge: edge.opposite)
                inputNetworkService?.send(leaveEvent, to: peer.id)
            }
        }
        
        statusMessage = "Running"
        print("MouseShareController: Returned to local control")
    }
    
    // MARK: - Private Methods - Event Batching
    
    private func startEventBatching(for peerId: UUID) {
        stopEventBatching()
        
        eventBatchTimer = Timer.scheduledTimer(withTimeInterval: eventBatchInterval, repeats: true) { [weak self] _ in
            Task { @MainActor in
                self?.flushEventBatch(to: peerId)
            }
        }
    }
    
    private func stopEventBatching() {
        eventBatchTimer?.invalidate()
        eventBatchTimer = nil
        pendingEvents.removeAll()
    }
    
    private func flushEventBatch(to peerId: UUID) {
        guard !pendingEvents.isEmpty else { return }
        
        let events = pendingEvents
        pendingEvents.removeAll()
        
        inputNetworkService?.send(events, to: peerId)
    }
    
    private func queueEvent(_ event: InputEvent) {
        pendingEvents.append(event)
        
        // Flush immediately for important events
        switch event.type {
        case .mouseDown, .mouseUp, .keyDown, .keyUp:
            if let peerId = activePeer?.id {
                flushEventBatch(to: peerId)
            }
        default:
            break
        }
    }
    
    // MARK: - Private Methods - Heartbeat
    
    private func startHeartbeat() {
        heartbeatTimer = Timer.scheduledTimer(withTimeInterval: heartbeatInterval, repeats: true) { [weak self] _ in
            Task { @MainActor in
                self?.sendHeartbeats()
            }
        }
    }
    
    private func stopHeartbeat() {
        heartbeatTimer?.invalidate()
        heartbeatTimer = nil
    }
    
    private func sendHeartbeats() {
        let heartbeat = InputEvent.heartbeat()
        
        for peer in connectedPeers {
            inputNetworkService?.send(heartbeat, to: peer.id)
        }
        
        // SAFETY: Check connection health when controlling
        // If we haven't heard from the active peer in too long, return to local
        if controlState == .controlling, let peer = activePeer {
            let timeSinceLastSeen = Date().timeIntervalSince(peer.lastSeen)
            let maxSilenceInterval: TimeInterval = 5.0  // 5 seconds without response
            
            if timeSinceLastSeen > maxSilenceInterval {
                print("MouseShareController: SAFETY - No response from \(peer.name) for \(timeSinceLastSeen)s, returning to local control")
                statusMessage = "Lost connection to \(peer.name)"
                returnToLocalControl()
            }
        }
    }
}

// MARK: - EventCaptureDelegate

extension MouseShareController: EventCaptureDelegate {
    nonisolated func eventCapture(_ service: EventCaptureService, didCapture event: InputEvent) {
        Task { @MainActor in
            // Forward event to active peer
            guard controlState == .controlling, let peer = activePeer else { return }
            queueEvent(event)
        }
    }
    
    nonisolated func eventCapture(_ service: EventCaptureService, mouseReachedEdge edge: ScreenEdge, at point: CGPoint) {
        Task { @MainActor in
            // Check if we have a peer linked to this edge
            guard let peerId = settings.screenConfig.peerForEdge(edge),
                  let peer = connectedPeers.first(where: { $0.id == peerId }) else {
                return
            }
            
            // Calculate relative position
            let bounds = DisplayInfo.combinedBounds
            let relativePosition: CGFloat
            switch edge {
            case .left, .right:
                relativePosition = (point.y - bounds.minY) / bounds.height
            case .top, .bottom:
                relativePosition = (point.x - bounds.minX) / bounds.width
            }
            
            // Transition to controlling
            transitionToControlling(peer: peer, edge: edge, position: relativePosition)
        }
    }
    
    nonisolated func eventCaptureDidRequestEscapeToLocal(_ service: EventCaptureService) {
        Task { @MainActor in
            // User pressed Escape while controlling remote - return to local control
            if controlState == .controlling {
                print("MouseShareController: Escape pressed - returning to local control")
                statusMessage = "Escaped to local control"
                returnToLocalControl()
            }
        }
    }
}

// MARK: - NetworkDiscoveryDelegate

extension MouseShareController: NetworkDiscoveryDelegate {
    nonisolated func networkDiscovery(_ service: NetworkDiscoveryService, didDiscover peer: Peer) {
        Task { @MainActor in
            if !discoveredPeers.contains(where: { $0.id == peer.id }) {
                discoveredPeers.append(peer)
                
                // Auto-connect if enabled
                if settings.autoConnectEnabled {
                    connect(to: peer)
                }
            }
        }
    }
    
    nonisolated func networkDiscovery(_ service: NetworkDiscoveryService, didLose peerId: UUID) {
        Task { @MainActor in
            discoveredPeers.removeAll { $0.id == peerId }
            
            // Handle if this was the active peer
            if activePeer?.id == peerId {
                returnToLocalControl()
            }
        }
    }
    
    nonisolated func networkDiscovery(_ service: NetworkDiscoveryService, didUpdatePeer peer: Peer) {
        Task { @MainActor in
            if let index = discoveredPeers.firstIndex(where: { $0.id == peer.id }) {
                discoveredPeers[index].lastSeen = peer.lastSeen
            }
        }
    }
}

// MARK: - InputNetworkDelegate

extension MouseShareController: InputNetworkDelegate {
    nonisolated func inputNetwork(_ service: InputNetworkService, didConnect peer: Peer) {
        Task { @MainActor in
            peer.state = .connected
            
            if !connectedPeers.contains(where: { $0.id == peer.id }) {
                connectedPeers.append(peer)
            }
            
            print("MouseShareController: Connected to \(peer.name)")
        }
    }
    
    nonisolated func inputNetwork(_ service: InputNetworkService, didDisconnect peerId: UUID) {
        Task { @MainActor in
            connectedPeers.removeAll { $0.id == peerId }
            
            if activePeer?.id == peerId {
                returnToLocalControl()
            }
        }
    }
    
    nonisolated func inputNetwork(_ service: InputNetworkService, didReceive event: InputEvent, from peerId: UUID) {
        Task { @MainActor in
            switch event.type {
            case .screenEnter:
                // Remote peer is entering our screen
                if let peer = connectedPeers.first(where: { $0.id == peerId }) {
                    transitionToControlled(by: peer)
                    
                    // Send acknowledgment back to the controlling peer
                    if let edge = event.screenEdge {
                        let ackEvent = InputEvent.screenEnterAck(edge: edge)
                        inputNetworkService?.send(ackEvent, to: peerId)
                    }
                    
                    // Move cursor to entry point
                    if let edge = event.screenEdge,
                       let entryX = event.entryX,
                       let entryY = event.entryY {
                        let entryPoint = screenEdgeService?.calculateEntryPoint(
                            edge: edge,
                            relativePosition: CGFloat(edge == .left || edge == .right ? entryY : entryX)
                        ) ?? CGPoint(x: 100, y: 100)
                        eventInjectionService?.moveMouse(to: entryPoint)
                    }
                }
                
            case .screenEnterAck:
                // Remote peer acknowledged our screen enter - connection is confirmed
                // Cancel the failsafe timer
                if controlState == .controlling && activePeer?.id == peerId {
                    print("MouseShareController: Received screenEnterAck - connection confirmed")
                    cancelTransitionFailsafe()
                    
                    // Update peer last seen
                    if let peer = connectedPeers.first(where: { $0.id == peerId }) {
                        peer.lastSeen = Date()
                    }
                }
                
            case .screenLeave:
                // Remote peer is leaving (returning control)
                returnToLocalControl()
                
            case .clipboardUpdate:
                // Update clipboard
                if settings.clipboardSyncEnabled,
                   let data = event.clipboardData,
                   let type = event.clipboardType {
                    clipboardService?.updateClipboard(with: data, type: type)
                }
                
            case .heartbeat:
                // Update peer last seen
                if let peer = connectedPeers.first(where: { $0.id == peerId }) {
                    peer.lastSeen = Date()
                }
                
            default:
                // Inject the event
                if controlState == .controlled {
                    eventInjectionService?.inject(event)
                }
            }
        }
    }
    
    nonisolated func inputNetwork(_ service: InputNetworkService, didReceive handshake: HandshakeRequest, from connection: NWConnection) {
        Task { @MainActor in
            // Accept the handshake
            inputNetworkService?.sendHandshakeResponse(to: connection, accepted: true)
            inputNetworkService?.registerConnection(connection, for: handshake.peerId)
            
            // Create peer from handshake
            let peer = Peer(id: handshake.peerId, name: handshake.peerName, hostName: "")
            peer.remoteScreenWidth = handshake.screenWidth
            peer.remoteScreenHeight = handshake.screenHeight
            peer.state = .connected
            
            if !connectedPeers.contains(where: { $0.id == peer.id }) {
                connectedPeers.append(peer)
            }
            
            print("MouseShareController: Accepted connection from \(peer.name)")
        }
    }
    
    nonisolated func inputNetwork(_ service: InputNetworkService, connectionError: Error, for peerId: UUID?) {
        Task { @MainActor in
            print("MouseShareController: Connection error: \(connectionError)")
            
            // If we're controlling a remote and the connection failed, return to local immediately
            if controlState == .controlling {
                if peerId == nil || activePeer?.id == peerId {
                    print("MouseShareController: Connection error while controlling - returning to local control")
                    statusMessage = "Connection error - returned to local"
                    returnToLocalControl()
                }
            } else if controlState == .controlled {
                // If we're being controlled and connection failed, we're now in local control
                if peerId == nil || activePeer?.id == peerId {
                    print("MouseShareController: Connection error while being controlled - returning to local control")
                    returnToLocalControl()
                }
            }
            
            // Also handle case where activePeer matches
            if let peerId = peerId, activePeer?.id == peerId {
                returnToLocalControl()
            }
        }
    }
}

// MARK: - ScreenEdgeDelegate

extension MouseShareController: ScreenEdgeDelegate {
    nonisolated func screenEdge(_ service: ScreenEdgeService, shouldTransitionAt edge: ScreenEdge, position: CGFloat) -> Bool {
        // This is called synchronously from the main thread
        // Check if we have a connected peer for this edge
        // Note: This is a workaround for actor isolation - in production, 
        // this should use a thread-safe cache of edge links
        return true  // Allow transition, actual check happens in delegate
    }
    
    nonisolated func screenEdge(_ service: ScreenEdgeService, didTransitionTo edge: ScreenEdge, position: CGFloat) {
        // Handled by eventCapture delegate
    }
    
    nonisolated func screenEdge(_ service: ScreenEdgeService, didReturnFrom edge: ScreenEdge) {
        Task { @MainActor in
            returnToLocalControl()
        }
    }
}

// MARK: - ClipboardDelegate

extension MouseShareController: ClipboardDelegate {
    nonisolated func clipboard(_ service: ClipboardService, didChange data: Data, type: String) {
        Task { @MainActor in
            guard settings.clipboardSyncEnabled else { return }
            
            // Send clipboard update to all connected peers
            let event = InputEvent.clipboardUpdate(data: data, type: type)
            
            for peer in connectedPeers {
                inputNetworkService?.send(event, to: peer.id)
            }
        }
    }
}
