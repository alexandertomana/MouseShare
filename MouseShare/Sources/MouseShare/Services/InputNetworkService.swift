import Foundation
import Network

// MARK: - Input Network Delegate

protocol InputNetworkDelegate: AnyObject {
    func inputNetwork(_ service: InputNetworkService, didConnect peer: Peer)
    func inputNetwork(_ service: InputNetworkService, didDisconnect peerId: UUID)
    func inputNetwork(_ service: InputNetworkService, didReceive event: InputEvent, from peerId: UUID)
    func inputNetwork(_ service: InputNetworkService, didReceive handshake: HandshakeRequest, from connection: NWConnection)
    func inputNetwork(_ service: InputNetworkService, connectionError: Error, for peerId: UUID?)
}

// MARK: - Input Network Service

/// Handles TCP connections for sending and receiving input events
final class InputNetworkService {
    
    // MARK: - Properties
    
    weak var delegate: InputNetworkDelegate?
    
    private var listener: NWListener?
    private var connections: [UUID: NWConnection] = [:]
    private var pendingConnections: [ObjectIdentifier: NWConnection] = [:]
    private let connectionQueue = DispatchQueue(label: "com.mouseshare.connections", attributes: .concurrent)
    
    // Local peer info
    private let localPeerId: UUID
    private let localPeerName: String
    private var localScreenWidth: Int
    private var localScreenHeight: Int
    
    // Encryption
    private var encryptionService: EncryptionService?
    
    // Packet sequencing
    private var sendSequence: UInt32 = 0
    private var receiveSequences: [UUID: UInt32] = [:]
    
    // Buffer for partial reads
    private var receiveBuffers: [UUID: Data] = [:]
    
    // MARK: - Initialization
    
    init(peerId: UUID, peerName: String, screenWidth: Int, screenHeight: Int) {
        self.localPeerId = peerId
        self.localPeerName = peerName
        self.localScreenWidth = screenWidth
        self.localScreenHeight = screenHeight
    }
    
    deinit {
        stopListening()
        disconnectAll()
    }
    
    // MARK: - Public Methods
    
    /// Enable encryption with password
    func enableEncryption(password: String) throws {
        encryptionService = try EncryptionService(password: password)
    }
    
    /// Disable encryption
    func disableEncryption() {
        encryptionService = nil
    }
    
    /// Start listening for incoming connections
    func startListening(port: UInt16 = NetworkDiscoveryService.defaultPort) -> Bool {
        do {
            let parameters = NWParameters.tcp
            parameters.includePeerToPeer = true
            
            // Allow address reuse
            parameters.allowLocalEndpointReuse = true
            
            let listener = try NWListener(using: parameters, on: NWEndpoint.Port(rawValue: port)!)
            
            listener.stateUpdateHandler = { [weak self] state in
                self?.handleListenerState(state)
            }
            
            listener.newConnectionHandler = { [weak self] connection in
                self?.handleIncomingConnection(connection)
            }
            
            listener.start(queue: .main)
            self.listener = listener
            
            print("InputNetworkService: Listening on port \(port)")
            return true
            
        } catch {
            print("InputNetworkService: Failed to start listener: \(error)")
            return false
        }
    }
    
    /// Stop listening for connections
    func stopListening() {
        listener?.cancel()
        listener = nil
    }
    
    /// Connect to a peer
    func connect(to peer: Peer) {
        guard let endpoint = peer.endpoint else {
            print("InputNetworkService: No endpoint for peer \(peer.name)")
            return
        }
        
        // Check if already connected
        if connectionQueue.sync(execute: { connections[peer.id] != nil }) {
            print("InputNetworkService: Already connected to \(peer.name)")
            return
        }
        
        let parameters = NWParameters.tcp
        parameters.includePeerToPeer = true
        
        let connection = NWConnection(to: endpoint, using: parameters)
        
        // Store as pending until handshake completes
        let connectionId = ObjectIdentifier(connection)
        connectionQueue.async(flags: .barrier) { [weak self] in
            self?.pendingConnections[connectionId] = connection
        }
        
        connection.stateUpdateHandler = { [weak self] state in
            self?.handleConnectionState(state, for: connection, peerId: peer.id)
        }
        
        connection.start(queue: .main)
        
        print("InputNetworkService: Connecting to \(peer.name)...")
    }
    
    /// Disconnect from a peer
    func disconnect(from peerId: UUID) {
        connectionQueue.async(flags: .barrier) { [weak self] in
            if let connection = self?.connections.removeValue(forKey: peerId) {
                connection.cancel()
            }
            self?.receiveBuffers.removeValue(forKey: peerId)
            self?.receiveSequences.removeValue(forKey: peerId)
        }
        
        print("InputNetworkService: Disconnected from \(peerId)")
        delegate?.inputNetwork(self, didDisconnect: peerId)
    }
    
    /// Disconnect from all peers
    func disconnectAll() {
        connectionQueue.async(flags: .barrier) { [weak self] in
            for (_, connection) in self?.connections ?? [:] {
                connection.cancel()
            }
            self?.connections.removeAll()
            
            for (_, connection) in self?.pendingConnections ?? [:] {
                connection.cancel()
            }
            self?.pendingConnections.removeAll()
            
            self?.receiveBuffers.removeAll()
            self?.receiveSequences.removeAll()
        }
    }
    
    /// Send an input event to a peer
    func send(_ event: InputEvent, to peerId: UUID) {
        guard let connection = connectionQueue.sync(execute: { connections[peerId] }) else {
            return
        }
        
        sendSequence += 1
        let packet = InputPacket(events: [event], sequenceNumber: sendSequence)
        
        do {
            var data = try packet.serialize()
            
            // Encrypt if enabled
            if let encryption = encryptionService {
                data = try encryption.encrypt(data)
            }
            
            // Prepend length header (4 bytes)
            var length = UInt32(data.count).bigEndian
            var framedData = Data(bytes: &length, count: 4)
            framedData.append(data)
            
            connection.send(content: framedData, completion: .contentProcessed { [weak self] error in
                if let error = error {
                    print("InputNetworkService: Send error: \(error)")
                    self?.delegate?.inputNetwork(self!, connectionError: error, for: peerId)
                }
            })
            
        } catch {
            print("InputNetworkService: Serialization error: \(error)")
        }
    }
    
    /// Send multiple events in a batch
    func send(_ events: [InputEvent], to peerId: UUID) {
        guard !events.isEmpty else { return }
        guard let connection = connectionQueue.sync(execute: { connections[peerId] }) else {
            return
        }
        
        sendSequence += 1
        let packet = InputPacket(events: events, sequenceNumber: sendSequence)
        
        do {
            var data = try packet.serialize()
            
            if let encryption = encryptionService {
                data = try encryption.encrypt(data)
            }
            
            var length = UInt32(data.count).bigEndian
            var framedData = Data(bytes: &length, count: 4)
            framedData.append(data)
            
            connection.send(content: framedData, completion: .contentProcessed { [weak self] error in
                if let error = error {
                    print("InputNetworkService: Batch send error: \(error)")
                    self?.delegate?.inputNetwork(self!, connectionError: error, for: peerId)
                }
            })
            
        } catch {
            print("InputNetworkService: Batch serialization error: \(error)")
        }
    }
    
    /// Send handshake request
    func sendHandshake(to connection: NWConnection, encryptionEnabled: Bool) {
        let request = HandshakeRequest(
            peerId: localPeerId,
            peerName: localPeerName,
            screenWidth: localScreenWidth,
            screenHeight: localScreenHeight,
            encryptionEnabled: encryptionEnabled,
            timestamp: UInt64(Date().timeIntervalSince1970 * 1000)
        )
        
        do {
            var data = try request.serialize()
            
            // Prepend length header
            var length = UInt32(data.count).bigEndian
            var framedData = Data(bytes: &length, count: 4)
            framedData.append(data)
            
            connection.send(content: framedData, completion: .contentProcessed { error in
                if let error = error {
                    print("InputNetworkService: Handshake send error: \(error)")
                }
            })
            
        } catch {
            print("InputNetworkService: Handshake serialization error: \(error)")
        }
    }
    
    /// Send handshake response
    func sendHandshakeResponse(to connection: NWConnection, accepted: Bool, errorMessage: String? = nil) {
        let response = HandshakeResponse(
            accepted: accepted,
            peerId: localPeerId,
            peerName: localPeerName,
            screenWidth: localScreenWidth,
            screenHeight: localScreenHeight,
            errorMessage: errorMessage
        )
        
        do {
            var data = try response.serialize()
            
            var length = UInt32(data.count).bigEndian
            var framedData = Data(bytes: &length, count: 4)
            framedData.append(data)
            
            connection.send(content: framedData, completion: .contentProcessed { error in
                if let error = error {
                    print("InputNetworkService: Handshake response error: \(error)")
                }
            })
            
        } catch {
            print("InputNetworkService: Handshake response serialization error: \(error)")
        }
    }
    
    /// Register a connection after successful handshake
    func registerConnection(_ connection: NWConnection, for peerId: UUID) {
        let connectionId = ObjectIdentifier(connection)
        
        connectionQueue.async(flags: .barrier) { [weak self] in
            self?.pendingConnections.removeValue(forKey: connectionId)
            self?.connections[peerId] = connection
            self?.receiveSequences[peerId] = 0
        }
        
        // Start receiving
        receiveData(from: connection, peerId: peerId)
    }
    
    // MARK: - Private Methods
    
    private func handleListenerState(_ state: NWListener.State) {
        switch state {
        case .ready:
            print("InputNetworkService: Listener ready")
        case .failed(let error):
            print("InputNetworkService: Listener failed: \(error)")
        case .cancelled:
            print("InputNetworkService: Listener cancelled")
        default:
            break
        }
    }
    
    private func handleIncomingConnection(_ connection: NWConnection) {
        print("InputNetworkService: Incoming connection from \(connection.endpoint)")
        
        let connectionId = ObjectIdentifier(connection)
        
        connectionQueue.async(flags: .barrier) { [weak self] in
            self?.pendingConnections[connectionId] = connection
        }
        
        connection.stateUpdateHandler = { [weak self] state in
            self?.handleIncomingConnectionState(state, for: connection)
        }
        
        connection.start(queue: .main)
    }
    
    private func handleIncomingConnectionState(_ state: NWConnection.State, for connection: NWConnection) {
        switch state {
        case .ready:
            // Wait for handshake
            receiveHandshake(from: connection)
            
        case .failed(let error):
            print("InputNetworkService: Incoming connection failed: \(error)")
            cleanupPendingConnection(connection)
            
        case .cancelled:
            cleanupPendingConnection(connection)
            
        default:
            break
        }
    }
    
    private func handleConnectionState(_ state: NWConnection.State, for connection: NWConnection, peerId: UUID) {
        switch state {
        case .ready:
            // Send handshake
            sendHandshake(to: connection, encryptionEnabled: encryptionService != nil)
            // Wait for response
            receiveHandshakeResponse(from: connection, peerId: peerId)
            
        case .failed(let error):
            print("InputNetworkService: Connection to \(peerId) failed: \(error)")
            cleanupConnection(for: peerId)
            delegate?.inputNetwork(self, connectionError: error, for: peerId)
            
        case .cancelled:
            cleanupConnection(for: peerId)
            delegate?.inputNetwork(self, didDisconnect: peerId)
            
        default:
            break
        }
    }
    
    private func receiveHandshake(from connection: NWConnection) {
        // Read length header first (4 bytes)
        connection.receive(minimumIncompleteLength: 4, maximumLength: 4) { [weak self] data, _, isComplete, error in
            guard let self = self else { return }
            
            if let error = error {
                print("InputNetworkService: Handshake receive error: \(error)")
                connection.cancel()
                return
            }
            
            guard let data = data, data.count == 4 else {
                print("InputNetworkService: Invalid handshake length header")
                connection.cancel()
                return
            }
            
            let length = data.withUnsafeBytes { $0.load(as: UInt32.self).bigEndian }
            
            // Read handshake data
            connection.receive(minimumIncompleteLength: Int(length), maximumLength: Int(length)) { [weak self] data, _, _, error in
                guard let self = self else { return }
                
                if let error = error {
                    print("InputNetworkService: Handshake data receive error: \(error)")
                    connection.cancel()
                    return
                }
                
                guard let data = data else {
                    connection.cancel()
                    return
                }
                
                do {
                    let handshake = try HandshakeRequest.deserialize(from: data)
                    self.delegate?.inputNetwork(self, didReceive: handshake, from: connection)
                } catch {
                    print("InputNetworkService: Handshake parse error: \(error)")
                    connection.cancel()
                }
            }
        }
    }
    
    private func receiveHandshakeResponse(from connection: NWConnection, peerId: UUID) {
        connection.receive(minimumIncompleteLength: 4, maximumLength: 4) { [weak self] data, _, _, error in
            guard let self = self else { return }
            
            if let error = error {
                print("InputNetworkService: Handshake response receive error: \(error)")
                self.cleanupConnection(for: peerId)
                return
            }
            
            guard let data = data, data.count == 4 else {
                self.cleanupConnection(for: peerId)
                return
            }
            
            let length = data.withUnsafeBytes { $0.load(as: UInt32.self).bigEndian }
            
            connection.receive(minimumIncompleteLength: Int(length), maximumLength: Int(length)) { [weak self] data, _, _, error in
                guard let self = self else { return }
                
                if let error = error {
                    print("InputNetworkService: Handshake response data error: \(error)")
                    self.cleanupConnection(for: peerId)
                    return
                }
                
                guard let data = data else {
                    self.cleanupConnection(for: peerId)
                    return
                }
                
                do {
                    let response = try HandshakeResponse.deserialize(from: data)
                    
                    if response.accepted {
                        // Register connection and start receiving
                        self.registerConnection(connection, for: peerId)
                        
                        // Notify delegate
                        let peer = Peer(id: response.peerId, name: response.peerName, hostName: "")
                        peer.remoteScreenWidth = response.screenWidth
                        peer.remoteScreenHeight = response.screenHeight
                        peer.state = .connected
                        
                        self.delegate?.inputNetwork(self, didConnect: peer)
                    } else {
                        print("InputNetworkService: Handshake rejected: \(response.errorMessage ?? "unknown")")
                        self.cleanupConnection(for: peerId)
                    }
                } catch {
                    print("InputNetworkService: Handshake response parse error: \(error)")
                    self.cleanupConnection(for: peerId)
                }
            }
        }
    }
    
    private func receiveData(from connection: NWConnection, peerId: UUID) {
        // Read length header
        connection.receive(minimumIncompleteLength: 4, maximumLength: 4) { [weak self] data, _, isComplete, error in
            guard let self = self else { return }
            
            if isComplete {
                self.disconnect(from: peerId)
                return
            }
            
            if let error = error {
                print("InputNetworkService: Receive error: \(error)")
                self.delegate?.inputNetwork(self, connectionError: error, for: peerId)
                return
            }
            
            guard let data = data, data.count == 4 else {
                // Continue receiving
                self.receiveData(from: connection, peerId: peerId)
                return
            }
            
            let length = data.withUnsafeBytes { $0.load(as: UInt32.self).bigEndian }
            
            // Read packet data
            connection.receive(minimumIncompleteLength: Int(length), maximumLength: Int(length)) { [weak self] data, _, _, error in
                guard let self = self else { return }
                
                if let error = error {
                    print("InputNetworkService: Packet receive error: \(error)")
                    self.delegate?.inputNetwork(self, connectionError: error, for: peerId)
                    return
                }
                
                if var data = data {
                    // Decrypt if enabled
                    if let encryption = self.encryptionService {
                        do {
                            data = try encryption.decrypt(data)
                        } catch {
                            print("InputNetworkService: Decryption error: \(error)")
                            self.receiveData(from: connection, peerId: peerId)
                            return
                        }
                    }
                    
                    // Parse packet
                    do {
                        let packet = try InputPacket.deserialize(from: data)
                        
                        // Check sequence
                        let expectedSeq = (self.receiveSequences[peerId] ?? 0) + 1
                        if packet.sequenceNumber != expectedSeq && expectedSeq > 1 {
                            print("InputNetworkService: Packet out of order (expected \(expectedSeq), got \(packet.sequenceNumber))")
                        }
                        self.receiveSequences[peerId] = packet.sequenceNumber
                        
                        // Deliver events
                        for event in packet.events {
                            self.delegate?.inputNetwork(self, didReceive: event, from: peerId)
                        }
                    } catch {
                        print("InputNetworkService: Packet parse error: \(error)")
                    }
                }
                
                // Continue receiving
                self.receiveData(from: connection, peerId: peerId)
            }
        }
    }
    
    private func cleanupConnection(for peerId: UUID) {
        connectionQueue.async(flags: .barrier) { [weak self] in
            if let connection = self?.connections.removeValue(forKey: peerId) {
                connection.cancel()
            }
            self?.receiveBuffers.removeValue(forKey: peerId)
            self?.receiveSequences.removeValue(forKey: peerId)
        }
    }
    
    private func cleanupPendingConnection(_ connection: NWConnection) {
        let connectionId = ObjectIdentifier(connection)
        connectionQueue.async(flags: .barrier) { [weak self] in
            self?.pendingConnections.removeValue(forKey: connectionId)
        }
        connection.cancel()
    }
}
