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
    
    // Track which edge we entered from when being controlled (to know which edge returns us)
    private var controlledEntryEdge: ScreenEdge?
    // Track if cursor has moved away from the entry edge (to prevent immediate return)
    private var hasMovedAwayFromEntryEdge: Bool = false
    
    // Track the edge and position we exited from (for returning to correct position)
    private var controllingExitEdge: ScreenEdge?
    private var controllingExitPosition: CGFloat = 0.5
    
    // Cooldown to prevent rapid re-transitions after returning
    private var transitionCooldownUntil: Date = .distantPast
    private let transitionCooldownDuration: TimeInterval = 0.5  // 500ms cooldown
    
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
    
    /// Write debug log to file for remote debugging
    private func debugLog(_ message: String) {
        let logPath = "/tmp/mouseshare_debug.log"
        let timestamp = ISO8601DateFormatter().string(from: Date())
        let line = "[\(timestamp)] \(message)\n"
        if let data = line.data(using: .utf8) {
            if FileManager.default.fileExists(atPath: logPath) {
                if let handle = FileHandle(forWritingAtPath: logPath) {
                    handle.seekToEndOfFile()
                    handle.write(data)
                    handle.closeFile()
                }
            } else {
                try? data.write(to: URL(fileURLWithPath: logPath))
            }
        }
        print(message)  // Also print to console
    }
    
    /// Start all services
    func start() {
        debugLog("start() called, isRunning=\(isRunning)")
        guard !isRunning else { 
            debugLog("Already running, returning")
            return 
        }
        
        // Check accessibility permission
        debugLog("Checking accessibility permission: \(hasAccessibilityPermission)")
        if !hasAccessibilityPermission {
            hasAccessibilityPermission = EventCaptureService.requestAccessibilityPermission()
            debugLog("After request, hasAccessibilityPermission=\(hasAccessibilityPermission)")
            if !hasAccessibilityPermission {
                statusMessage = "Accessibility permission required"
                debugLog("No accessibility permission, returning")
                return
            }
        }
        
        // Clear any stale discovered peers
        deduplicateDiscoveredPeers()
        
        // Initialize screen arrangement with local displays
        if settings.screenConfig.arrangement.localScreens.isEmpty {
            settings.screenConfig.arrangement.initializeLocalDisplays()
            settings.save()
            debugLog("Initialized local display arrangement")
        }
        
        // Log current arrangement for debugging
        debugLog("=== SCREEN ARRANGEMENT ===")
        for screen in settings.screenConfig.arrangement.screens {
            debugLog("  \(screen.isLocal ? "LOCAL" : "REMOTE"): \(screen.name) (\(screen.width)x\(screen.height)) at (\(screen.x), \(screen.y)) peerId=\(String(describing: screen.peerId))")
        }
        debugLog("==========================")
        
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
    
    /// Remove duplicate peers from the discovered list
    private func deduplicateDiscoveredPeers() {
        var seenNames = Set<String>()
        var uniquePeers: [Peer] = []
        
        for peer in discoveredPeers {
            if !seenNames.contains(peer.name) {
                seenNames.insert(peer.name)
                uniquePeers.append(peer)
            }
        }
        
        let removed = discoveredPeers.count - uniquePeers.count
        if removed > 0 {
            print("MouseShareController: Removed \(removed) duplicate peers")
            discoveredPeers = uniquePeers
        }
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
        debugLog("connect() called for peer: \(peer.name), isRunning=\(isRunning)")
        guard isRunning else { 
            debugLog("Cannot connect - not running")
            return 
        }
        
        debugLog("Peer endpoint: \(String(describing: peer.endpoint))")
        guard peer.endpoint != nil else {
            debugLog("Cannot connect to \(peer.name) - no endpoint")
            statusMessage = "No endpoint for \(peer.name)"
            return
        }
        
        debugLog("Connecting to \(peer.name)...")
        peer.state = .connecting
        statusMessage = "Connecting to \(peer.name)..."
        inputNetworkService?.connect(to: peer)
        debugLog("connect() call completed")
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
        debugLog("startServices() called")
        
        // Start event capture
        let eventCaptureResult = eventCaptureService?.start() ?? false
        debugLog("Event capture result: \(eventCaptureResult)")
        if !eventCaptureResult {
            debugLog("Failed to start event capture - check Accessibility permissions")
            statusMessage = "Failed: Accessibility permission needed"
            return false
        }
        debugLog("Event capture started successfully")
        
        // Start network discovery
        let discoveryResult = networkDiscoveryService?.start() ?? false
        debugLog("Network discovery result: \(discoveryResult)")
        if !discoveryResult {
            debugLog("Failed to start network discovery")
            statusMessage = "Failed: Network discovery error"
            return false
        }
        debugLog("Network discovery started successfully")
        
        // Start input network listener
        let listenerResult = inputNetworkService?.startListening() ?? false
        debugLog("Input listener result: \(listenerResult)")
        if !listenerResult {
            debugLog("Failed to start input listener - port may be in use")
            statusMessage = "Failed: Port 24801 may be in use"
            return false
        }
        debugLog("Input listener started successfully")
        
        // Start clipboard monitoring if enabled
        if settings.clipboardSyncEnabled {
            clipboardService?.startMonitoring()
        }
        
        debugLog("All services started successfully")
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
        
        // Store where we exited from (for returning to correct position)
        controllingExitEdge = edge
        controllingExitPosition = position
        
        // Tell the capture service to forward events instead of local processing
        eventCaptureService?.setControlling(false)
        
        // Hide local cursor
        eventInjectionService?.setCursorVisible(false)
        CGDisplayHideCursor(CGMainDisplayID())
        
        // Park cursor at center of screen to prevent drift issues
        eventInjectionService?.parkCursor()
        
        // Disassociate mouse from cursor - physical mouse movement won't move visible cursor
        CGAssociateMouseAndMouseCursorPosition(0)
        
        // Send screen enter event to peer
        // Calculate entry point using the screen arrangement for proper overlap handling
        var entryX: Float
        var entryY: Float
        
        // Try to use arrangement-based calculation for accurate entry point
        if let screenPair = settings.screenConfig.arrangement.screenPair(forEdge: edge) {
            let entryPosition = settings.screenConfig.arrangement.calculateEntryPosition(
                exitPoint: position,
                from: screenPair.local,
                to: screenPair.remote,
                edge: edge
            )
            
            switch edge {
            case .left, .right:
                // Exit left -> enter right (1.0), exit right -> enter left (0.0)
                entryX = (edge == .left) ? 1.0 : 0.0
                entryY = Float(entryPosition)
            case .top, .bottom:
                entryX = Float(entryPosition)
                // Exit top -> enter bottom (1.0), exit bottom -> enter top (0.0)
                entryY = (edge == .top) ? 1.0 : 0.0
            }
            debugLog("Arrangement-based entry: exitPos=\(position), entryPos=\(entryPosition)")
        } else {
            // Fallback: simple relative position
            switch edge {
            case .left, .right:
                entryX = (edge == .left) ? 1.0 : 0.0
                entryY = Float(position)
            case .top, .bottom:
                entryX = Float(position)
                entryY = (edge == .top) ? 1.0 : 0.0
            }
            debugLog("Fallback entry calculation (no arrangement found)")
        }
        
        // Safety: ensure values are valid (not inf, nan, or out of range)
        if !entryX.isFinite { entryX = 0.5 }
        if !entryY.isFinite { entryY = 0.5 }
        entryX = max(0.0, min(1.0, entryX))
        entryY = max(0.0, min(1.0, entryY))
        
        let enterEvent = InputEvent.screenEnter(edge: edge.opposite, x: entryX, y: entryY)
        debugLog("Sending screenEnter event to \(peer.name): edge=\(edge.opposite), x=\(entryX), y=\(entryY)")
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
        // Allow connected, controlling, or controlled states as all are "alive"
        return connectedPeers.contains { peer in
            peer.id == peerId && (peer.state == .connected || peer.state == .controlling || peer.state == .controlled)
        }
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
                debugLog("FAILSAFE: No response from \(peer.name) for \(timeSinceLastSeen)s, returning to local")
                statusMessage = "Lost connection to \(peer.name)"
                returnToLocalControl()
            } else {
                // Connection seems alive, but we still haven't received ack - wait a bit more
                // Restart the failsafe timer
                print("MouseShareController: FAILSAFE - Peer alive but no ack yet, extending timeout")
                startTransitionFailsafe()
            }
        } else {
            // No pending peer info, something is wrong - return to local
            print("MouseShareController: FAILSAFE - Invalid state, returning to local control")
            debugLog("FAILSAFE: Invalid state (no pending peer), returning to local")
            returnToLocalControl()
        }
    }
    
    private func transitionToControlled(by peer: Peer) {
        debugLog("transitionToControlled() by \(peer.name)")
        controlState = .controlled
        activePeer = peer
        peer.state = .controlled
        
        // IMPORTANT: Disable edge detection while being controlled
        // This prevents injected mouse events from triggering edge transitions
        eventCaptureService?.setControlling(false)
        
        // Show cursor and prepare for remote input
        eventInjectionService?.setCursorVisible(true)
        eventInjectionService?.setRemoteScreenBounds(
            width: peer.remoteScreenWidth,
            height: peer.remoteScreenHeight
        )
        
        statusMessage = "Controlled by \(peer.name)"
        debugLog("Now being controlled by \(peer.name)")
    }
    
    private func returnToLocalControl() {
        debugLog("returnToLocalControl() called, previous state: \(controlState), activePeer: \(String(describing: activePeer?.name))")
        let previousPeer = activePeer
        let wasControlling = controlState == .controlling
        let wasControlled = controlState == .controlled
        
        // Cancel any pending failsafe timer
        cancelTransitionFailsafe()
        
        controlState = .local
        activePeer = nil
        
        // Tell capture service to process events locally (re-enable edge detection)
        eventCaptureService?.setControlling(true)
        
        // Re-associate mouse and cursor FIRST (was disassociated when controlling)
        CGAssociateMouseAndMouseCursorPosition(1)
        
        // If we were CONTROLLING a remote, warp to our exit position
        if wasControlling, let exitEdge = controllingExitEdge {
            debugLog("Was controlling: warping to \(exitEdge) edge at position \(controllingExitPosition)")
            eventInjectionService?.warpToEdge(exitEdge, relativePosition: controllingExitPosition)
        }
        
        // Now show cursor (after warping to correct position)
        CGDisplayShowCursor(CGMainDisplayID())
        eventInjectionService?.setCursorVisible(true)
        
        // Stop event batching
        stopEventBatching()
        
        // Reset screen edge state
        screenEdgeService?.resetTransitionState()
        
        // Clear tracking state
        controllingExitEdge = nil
        controllingExitPosition = 0.5
        controlledEntryEdge = nil
        hasMovedAwayFromEntryEdge = false
        
        // Set cooldown to prevent immediate re-transition
        transitionCooldownUntil = Date().addingTimeInterval(transitionCooldownDuration)
        
        if let peer = previousPeer {
            peer.state = .connected
            // Notify the peer we're leaving (only if we were controlling them)
            if wasControlling, let edge = pendingTransitionEdge {
                let leaveEvent = InputEvent.screenLeave(edge: edge.opposite)
                inputNetworkService?.send(leaveEvent, to: peer.id)
                debugLog("Sent screenLeave to \(peer.name)")
            }
        }
        
        statusMessage = "Running"
        debugLog("Returned to local control (was \(wasControlling ? "controlling" : wasControlled ? "controlled" : "local"))")
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
            // Don't transition if already controlling or being controlled
            guard controlState == .local else { 
                debugLog("Edge \(edge) reached but ignoring - controlState=\(controlState)")
                return 
            }
            
            // Check cooldown to prevent rapid re-transitions
            if Date() < transitionCooldownUntil {
                let remaining = transitionCooldownUntil.timeIntervalSinceNow
                debugLog("Edge \(edge) reached but in cooldown (\(remaining)s remaining)")
                return
            }
            
            // Check if we have a peer linked to this edge
            let peerId = settings.screenConfig.peerForEdge(edge)
            debugLog("Edge \(edge) reached at \(point), peerId=\(String(describing: peerId)), connectedPeers=\(connectedPeers.map { $0.name }), controlState=\(controlState)")
            
            guard let peerId = peerId,
                  let peer = connectedPeers.first(where: { $0.id == peerId }) else {
                // No peer linked - try to auto-link if there's only one connected peer
                if connectedPeers.count == 1, let peer = connectedPeers.first {
                    debugLog("Auto-linking \(edge) edge to only connected peer: \(peer.name)")
                    settings.screenConfig.setLink(edge: edge, peerId: peer.id, peerEdge: edge.opposite)
                    settings.save()
                    // Now proceed with transition
                    let bounds = DisplayInfo.combinedBounds
                    guard bounds.width > 0 && bounds.height > 0 else {
                        debugLog("ERROR: Invalid screen bounds: \(bounds)")
                        return
                    }
                    var relativePosition: CGFloat
                    switch edge {
                    case .left, .right:
                        relativePosition = (point.y - bounds.minY) / bounds.height
                    case .top, .bottom:
                        relativePosition = (point.x - bounds.minX) / bounds.width
                    }
                    relativePosition = max(0.0, min(1.0, relativePosition))
                    transitionToControlling(peer: peer, edge: edge, position: relativePosition)
                    return
                }
                debugLog("No peer linked to \(edge) edge")
                return
            }
            
            // Calculate relative position with safety checks
            let bounds = DisplayInfo.combinedBounds
            guard bounds.width > 0 && bounds.height > 0 else {
                debugLog("ERROR: Invalid screen bounds: \(bounds)")
                return
            }
            
            var relativePosition: CGFloat
            switch edge {
            case .left, .right:
                relativePosition = (point.y - bounds.minY) / bounds.height
            case .top, .bottom:
                relativePosition = (point.x - bounds.minX) / bounds.width
            }
            
            // Clamp to valid range
            relativePosition = max(0.0, min(1.0, relativePosition))
            
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
            // Check for duplicates by both ID and name to prevent duplicates
            let existsByID = discoveredPeers.contains { $0.id == peer.id }
            let existsByName = discoveredPeers.contains { $0.name == peer.name }
            
            if existsByID || existsByName {
                // Update existing peer instead of adding duplicate
                if let existingIndex = discoveredPeers.firstIndex(where: { $0.id == peer.id || $0.name == peer.name }) {
                    let existing = discoveredPeers[existingIndex]
                    existing.lastSeen = peer.lastSeen
                    existing.endpoint = peer.endpoint
                    existing.remoteScreenWidth = peer.remoteScreenWidth
                    existing.remoteScreenHeight = peer.remoteScreenHeight
                    print("MouseShareController: Updated existing peer '\(peer.name)'")
                }
                return
            }
            
            discoveredPeers.append(peer)
            print("MouseShareController: Added new peer '\(peer.name)'")
            
            // Auto-connect if enabled
            if settings.autoConnectEnabled {
                connect(to: peer)
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
            // Try to find by ID first, then by name
            if let index = discoveredPeers.firstIndex(where: { $0.id == peer.id || $0.name == peer.name }) {
                discoveredPeers[index].lastSeen = peer.lastSeen
                discoveredPeers[index].endpoint = peer.endpoint
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
            
            // Update screen arrangement with this peer's screen info
            settings.screenConfig.arrangement.updateRemoteScreen(
                peerId: peer.id,
                name: peer.displayName,
                width: peer.remoteScreenWidth,
                height: peer.remoteScreenHeight
            )
            settings.save()
            
            print("MouseShareController: Connected to \(peer.name) (\(peer.remoteScreenWidth)x\(peer.remoteScreenHeight))")
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
                debugLog("Received screenEnter event from \(peerId)")
                if let peer = connectedPeers.first(where: { $0.id == peerId }) {
                    debugLog("Found peer \(peer.name), transitioning to controlled")
                    
                    // Store which edge we entered from (to know which edge returns us)
                    controlledEntryEdge = event.screenEdge
                    hasMovedAwayFromEntryEdge = false  // Reset - must move away before can return
                    debugLog("Entry edge: \(String(describing: controlledEntryEdge))")
                    
                    transitionToControlled(by: peer)
                    
                    // Send acknowledgment back to the controlling peer
                    if let edge = event.screenEdge {
                        let ackEvent = InputEvent.screenEnterAck(edge: edge)
                        inputNetworkService?.send(ackEvent, to: peerId)
                        debugLog("Sent screenEnterAck")
                    }
                    
                    // Move cursor to entry point
                    if let edge = event.screenEdge,
                       let entryX = event.entryX,
                       let entryY = event.entryY {
                        let entryPoint = screenEdgeService?.calculateEntryPoint(
                            edge: edge,
                            relativePosition: CGFloat(edge == .left || edge == .right ? entryY : entryX)
                        ) ?? CGPoint(x: 100, y: 100)
                        debugLog("Moving cursor to \(entryPoint)")
                        eventInjectionService?.moveMouse(to: entryPoint)
                    }
                } else {
                    debugLog("ERROR: No peer found for \(peerId) in connectedPeers")
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
                debugLog("Received screenLeave from \(peerId) - returning to local control")
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
                    
                    // Check for edge crossing to return control
                    // Only check on mouse move events, not clicks or drags
                    if event.type == .mouseMove, let x = event.x, let y = event.y {
                        checkForReturnEdgeCrossing(x: x, y: y, controllerPeerId: peerId)
                    }
                } else {
                    debugLog("Ignoring event type \(event.type) - controlState=\(controlState), expected=.controlled")
                }
            }
        }
    }
    
    /// Check if cursor position has crossed an edge to return control to the controller
    private func checkForReturnEdgeCrossing(x: Float, y: Float, controllerPeerId: UUID) {
        // Only check for return if we know which edge we entered from AND we're being controlled
        guard controlState == .controlled else { return }
        guard let entryEdge = controlledEntryEdge else { 
            debugLog("WARNING: checkForReturnEdgeCrossing called but no entryEdge set")
            return 
        }
        
        // Get the ACTUAL current cursor position using CGEvent (CG coordinates, top-left origin)
        // This is consistent with CGDisplayBounds
        guard let cgEvent = CGEvent(source: nil) else { return }
        let point = cgEvent.location
        
        // Use CGMainDisplayID bounds for consistency (CG coordinates)
        let mainDisplay = CGMainDisplayID()
        let bounds = CGDisplayBounds(mainDisplay)
        
        // Safety check - if bounds are invalid, don't proceed
        guard bounds.width > 0 && bounds.height > 0 else {
            debugLog("ERROR: Invalid bounds in checkForReturnEdgeCrossing: \(bounds)")
            return
        }
        
        // Log first time for debugging
        if !hasMovedAwayFromEntryEdge {
            debugLog("Return check started: cursorPos=\(point), bounds=\(bounds), entryEdge=\(entryEdge), movedAway=\(hasMovedAwayFromEntryEdge)")
        }
        
        let edgeThreshold: CGFloat = 3.0  // Very close to edge required
        let awayThreshold: CGFloat = 300.0  // Must move 300px before can return
        
        // Check if cursor is at the entry edge
        // CG coordinates: origin at top-left, Y increases going DOWN
        var atEntryEdge = false
        var distanceFromEntryEdge: CGFloat = 0
        
        switch entryEdge {
        case .left:
            distanceFromEntryEdge = point.x - bounds.minX
            atEntryEdge = distanceFromEntryEdge <= edgeThreshold
        case .right:
            distanceFromEntryEdge = bounds.maxX - point.x
            atEntryEdge = distanceFromEntryEdge <= edgeThreshold
        case .top:
            // Top of screen = minY in CG coordinates
            distanceFromEntryEdge = point.y - bounds.minY
            atEntryEdge = distanceFromEntryEdge <= edgeThreshold
        case .bottom:
            // Bottom of screen = maxY in CG coordinates
            distanceFromEntryEdge = bounds.maxY - point.y
            atEntryEdge = distanceFromEntryEdge <= edgeThreshold
        }
        
        // First, check if cursor has moved away from the entry edge
        if !hasMovedAwayFromEntryEdge {
            if distanceFromEntryEdge > awayThreshold {
                hasMovedAwayFromEntryEdge = true
                debugLog("Cursor moved away from entry edge (distance: \(distanceFromEntryEdge))")
            }
            return  // Don't check for return until we've moved away
        }
        
        // Now check if cursor has returned to the entry edge
        if atEntryEdge {
            debugLog("!!! RETURN TRIGGERED: Cursor returned to \(entryEdge.displayName) edge. pos=\(point), distance=\(distanceFromEntryEdge)")
            
            // Send screenLeave to tell controller we're returning
            let leaveEvent = InputEvent.screenLeave(edge: entryEdge)
            inputNetworkService?.send(leaveEvent, to: controllerPeerId)
            debugLog("Sent screenLeave to controller")
            
            // Clear state and return to local
            controlledEntryEdge = nil
            hasMovedAwayFromEntryEdge = false
            returnToLocalControl()
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
