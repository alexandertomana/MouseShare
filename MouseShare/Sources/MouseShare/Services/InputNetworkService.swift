import Foundation
import Network
import Darwin

// MARK: - BSD Socket Listener

/// A simple BSD socket-based TCP listener that accepts connections
/// and wraps them for use with Network.framework
private class BSDSocketListener {
    private var serverSocket: Int32 = -1
    private var isListening = false
    private var acceptThread: Thread?
    var onNewConnection: ((Int32, String) -> Void)?
    
    func start(port: UInt16) -> Bool {
        // Create IPv6 socket (dual-stack)
        serverSocket = socket(AF_INET6, SOCK_STREAM, 0)
        guard serverSocket >= 0 else {
            print("BSDSocketListener: Failed to create socket: \(errno)")
            return false
        }
        
        // Set socket options
        var yes: Int32 = 1
        setsockopt(serverSocket, SOL_SOCKET, SO_REUSEADDR, &yes, socklen_t(MemoryLayout<Int32>.size))
        
        // Enable dual-stack (accept IPv4 on IPv6 socket)
        var no: Int32 = 0
        setsockopt(serverSocket, IPPROTO_IPV6, IPV6_V6ONLY, &no, socklen_t(MemoryLayout<Int32>.size))
        
        // Bind to all interfaces
        var addr = sockaddr_in6()
        addr.sin6_len = UInt8(MemoryLayout<sockaddr_in6>.size)
        addr.sin6_family = sa_family_t(AF_INET6)
        addr.sin6_port = port.bigEndian
        addr.sin6_addr = in6addr_any
        
        let bindResult = withUnsafePointer(to: &addr) { ptr in
            ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockaddrPtr in
                bind(serverSocket, sockaddrPtr, socklen_t(MemoryLayout<sockaddr_in6>.size))
            }
        }
        
        guard bindResult == 0 else {
            print("BSDSocketListener: Failed to bind: \(errno)")
            close(serverSocket)
            serverSocket = -1
            return false
        }
        
        // Listen
        guard Darwin.listen(serverSocket, 5) == 0 else {
            print("BSDSocketListener: Failed to listen: \(errno)")
            close(serverSocket)
            serverSocket = -1
            return false
        }
        
        isListening = true
        print("BSDSocketListener: Listening on port \(port) (dual-stack)")
        
        // Start accept thread
        acceptThread = Thread { [weak self] in
            self?.acceptLoop()
        }
        acceptThread?.start()
        
        return true
    }
    
    func stop() {
        isListening = false
        if serverSocket >= 0 {
            close(serverSocket)
            serverSocket = -1
        }
    }
    
    private func acceptLoop() {
        while isListening && serverSocket >= 0 {
            var clientAddr = sockaddr_in6()
            var addrLen = socklen_t(MemoryLayout<sockaddr_in6>.size)
            
            let clientSocket = withUnsafeMutablePointer(to: &clientAddr) { ptr in
                ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockaddrPtr in
                    accept(serverSocket, sockaddrPtr, &addrLen)
                }
            }
            
            if clientSocket >= 0 {
                // Get client address string
                var hostBuffer = [CChar](repeating: 0, count: Int(NI_MAXHOST))
                withUnsafePointer(to: &clientAddr) { ptr in
                    ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockaddrPtr in
                        getnameinfo(sockaddrPtr, addrLen, &hostBuffer, socklen_t(hostBuffer.count), nil, 0, NI_NUMERICHOST)
                    }
                }
                let clientHost = String(cString: hostBuffer)
                
                print("BSDSocketListener: Accepted connection from \(clientHost)")
                DispatchQueue.main.async { [weak self] in
                    self?.onNewConnection?(clientSocket, clientHost)
                }
            } else if errno != EINTR && errno != EWOULDBLOCK {
                if isListening {
                    print("BSDSocketListener: Accept failed: \(errno)")
                }
            }
        }
    }
}

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
    private var bsdListener: BSDSocketListener?
    private var connections: [UUID: NWConnection] = [:]
    private var bsdConnections: [UUID: DispatchIO] = [:]  // BSD socket connections by peer ID
    private var bsdSocketToPeerId: [Int32: UUID] = [:]  // Map socket FD to peer ID
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
        // Use BSD socket listener for cross-network compatibility
        // NWListener has issues with IPv6-only sockets not accepting IPv4 connections
        let bsd = BSDSocketListener()
        
        bsd.onNewConnection = { [weak self] clientSocket, clientHost in
            self?.handleBSDConnection(socket: clientSocket, from: clientHost)
        }
        
        if bsd.start(port: port) {
            self.bsdListener = bsd
            print("InputNetworkService: BSD Listener started on port \(port)")
            return true
        } else {
            print("InputNetworkService: Failed to start BSD listener")
            return false
        }
    }
    
    /// Handle a new connection from BSD socket listener
    private func handleBSDConnection(socket: Int32, from host: String) {
        print("InputNetworkService: New BSD connection from \(host)")
        
        // Create NWConnection from the socket file descriptor using a workaround:
        // We'll create a connection to the remote endpoint based on what we know
        // For now, store the raw socket and handle it via DispatchIO
        
        // Get the remote address info from the socket
        var addr = sockaddr_in6()
        var addrLen = socklen_t(MemoryLayout<sockaddr_in6>.size)
        getpeername(socket, 
                    UnsafeMutableRawPointer(&addr).assumingMemoryBound(to: sockaddr.self), 
                    &addrLen)
        
        let port = UInt16(bigEndian: addr.sin6_port)
        
        // Create NWConnection to the peer (this is a workaround)
        // Actually, we can't easily create an NWConnection from an existing socket
        // So let's handle the raw socket with DispatchIO
        
        let channel = DispatchIO(type: .stream, 
                                  fileDescriptor: socket, 
                                  queue: .main) { error in
            if error != 0 {
                print("InputNetworkService: DispatchIO error: \(error)")
            }
            Darwin.close(socket)
        }
        
        // Set up reading from the socket
        startReadingFromSocket(channel: channel, socket: socket, host: host)
    }
    
    /// Read data from a raw socket using DispatchIO
    private func startReadingFromSocket(channel: DispatchIO, socket: Int32, host: String) {
        // Read length-prefixed messages
        readLengthPrefixedMessage(from: channel, socket: socket, host: host)
    }
    
    /// Read a length-prefixed message from the socket
    private func readLengthPrefixedMessage(from channel: DispatchIO, socket: Int32, host: String) {
        // First read the 4-byte length header
        channel.read(offset: 0, length: 4, queue: .main) { [weak self] done, data, error in
            guard let self = self else { return }
            
            if error != 0 {
                print("InputNetworkService: Read error: \(error)")
                channel.close()
                return
            }
            
            guard let data = data, data.count == 4 else {
                if done {
                    print("InputNetworkService: Connection closed from \(host)")
                    channel.close()
                }
                return
            }
            
            // Parse length from DispatchData
            var length: UInt32 = 0
            data.enumerateBytes { buffer, offset, stop in
                if buffer.count >= 4, let basePtr = buffer.baseAddress {
                    length = basePtr.withMemoryRebound(to: UInt32.self, capacity: 1) { $0.pointee.bigEndian }
                    stop = true
                }
            }
            
            // Read the message body
            channel.read(offset: 0, length: Int(length), queue: .main) { [weak self] done, bodyData, error in
                guard let self = self else { return }
                
                if error != 0 {
                    print("InputNetworkService: Body read error: \(error)")
                    channel.close()
                    return
                }
                
                if let bodyData = bodyData, bodyData.count > 0 {
                    // Convert to Data and process
                    let messageData = Data(bodyData)
                    self.processIncomingBSDMessage(messageData, from: host, channel: channel, socket: socket)
                }
                
                // Continue reading
                if !done {
                    self.readLengthPrefixedMessage(from: channel, socket: socket, host: host)
                }
            }
        }
    }
    
    /// Process a message from a BSD socket connection
    private func processIncomingBSDMessage(_ data: Data, from host: String, channel: DispatchIO, socket: Int32) {
        // Try to parse as handshake request first
        if let handshake = try? HandshakeRequest.deserialize(from: data) {
            print("InputNetworkService: Received handshake from \(handshake.peerName) via BSD socket")
            
            // Create a response and send it
            let response = HandshakeResponse(
                accepted: true,
                peerId: localPeerId,
                peerName: localPeerName,
                screenWidth: localScreenWidth,
                screenHeight: localScreenHeight,
                errorMessage: nil
            )
            
            if let responseData = try? response.serialize() {
                sendViaBSD(data: responseData, channel: channel)
            }
            
            // Register this BSD connection
            let peerId = handshake.peerId
            connectionQueue.async(flags: .barrier) { [weak self] in
                self?.bsdConnections[peerId] = channel
                self?.bsdSocketToPeerId[socket] = peerId
                self?.receiveSequences[peerId] = 0
            }
            
            // Create peer and notify delegate
            let peer = Peer(id: peerId, name: handshake.peerName, hostName: host)
            peer.remoteScreenWidth = handshake.screenWidth
            peer.remoteScreenHeight = handshake.screenHeight
            peer.state = .connected
            
            print("InputNetworkService: BSD connection registered for \(handshake.peerName)")
            delegate?.inputNetwork(self, didConnect: peer)
        }
        // Try to parse as input packet
        else if let packet = try? InputPacket.deserialize(from: data) {
            // Find the peer ID from the socket mapping
            let peerId = connectionQueue.sync { bsdSocketToPeerId[socket] }
            
            if let peerId = peerId {
                // Check sequence
                let expectedSeq = (receiveSequences[peerId] ?? 0) + 1
                if packet.sequenceNumber != expectedSeq && expectedSeq > 1 {
                    print("InputNetworkService: BSD packet out of order (expected \(expectedSeq), got \(packet.sequenceNumber))")
                }
                receiveSequences[peerId] = packet.sequenceNumber
                
                // Deliver events to delegate
                for event in packet.events {
                    delegate?.inputNetwork(self, didReceive: event, from: peerId)
                }
            } else {
                print("InputNetworkService: Received event from unknown BSD socket \(socket)")
            }
        }
    }
    
    /// Send data via BSD socket channel
    private func sendViaBSD(data: Data, channel: DispatchIO) {
        // Prepend length
        var length = UInt32(data.count).bigEndian
        var fullData = Data(bytes: &length, count: 4)
        fullData.append(data)
        
        fullData.withUnsafeBytes { ptr in
            let dispatchData = DispatchData(bytes: ptr)
            channel.write(offset: 0, data: dispatchData, queue: .main) { done, data, error in
                if error != 0 {
                    print("InputNetworkService: Write error: \(error)")
                }
            }
        }
    }
    
    /// Stop listening for connections
    func stopListening() {
        listener?.cancel()
        listener = nil
        bsdListener?.stop()
        bsdListener = nil
    }
    
    /// Connect to a peer
    func connect(to peer: Peer) {
        guard let endpoint = peer.endpoint else {
            print("InputNetworkService: ERROR - No endpoint for peer \(peer.name)")
            delegate?.inputNetwork(self, connectionError: NSError(domain: "MouseShare", code: -1, userInfo: [NSLocalizedDescriptionKey: "No endpoint for peer"]), for: peer.id)
            return
        }
        
        // Check if already connected
        if connectionQueue.sync(execute: { connections[peer.id] != nil }) {
            print("InputNetworkService: Already connected to \(peer.name)")
            return
        }
        
        // Check if already connecting
        let isConnecting = connectionQueue.sync { 
            pendingConnections.values.contains { conn in
                if case .service = conn.endpoint, case .service = endpoint {
                    return true
                }
                return false
            }
        }
        if isConnecting {
            print("InputNetworkService: Already connecting to \(peer.name)")
            return
        }
        
        // Create TCP parameters - allow any interface (WiFi, Ethernet, etc.)
        let parameters = NWParameters.tcp
        parameters.prohibitedInterfaceTypes = [.cellular, .loopback]
        // Don't require specific interface type - allow WiFi, Ethernet, etc.
        
        // Create connection to the peer's endpoint  
        print("InputNetworkService: Connecting to endpoint \(endpoint) for peer \(peer.name)")
        let connection = NWConnection(to: endpoint, using: parameters)
        
        // Store as pending until handshake completes
        let connectionId = ObjectIdentifier(connection)
        connectionQueue.async(flags: .barrier) { [weak self] in
            self?.pendingConnections[connectionId] = connection
        }
        
        connection.stateUpdateHandler = { [weak self] state in
            print("InputNetworkService: Connection state for \(peer.name): \(state)")
            self?.handleConnectionState(state, for: connection, peerId: peer.id)
        }
        
        connection.start(queue: .main)
        
        print("InputNetworkService: Started connection to \(peer.name)...")
    }
    
    /// Disconnect from a peer
    func disconnect(from peerId: UUID) {
        connectionQueue.async(flags: .barrier) { [weak self] in
            if let connection = self?.connections.removeValue(forKey: peerId) {
                connection.cancel()
            }
            if let channel = self?.bsdConnections.removeValue(forKey: peerId) {
                channel.close()
            }
            // Clean up socket-to-peer mapping
            self?.bsdSocketToPeerId = self?.bsdSocketToPeerId.filter { $0.value != peerId } ?? [:]
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
            
            for (_, channel) in self?.bsdConnections ?? [:] {
                channel.close()
            }
            self?.bsdConnections.removeAll()
            self?.bsdSocketToPeerId.removeAll()
            
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
        // Check for NWConnection first, then BSD connection
        let nwConnection = connectionQueue.sync { connections[peerId] }
        let bsdChannel = connectionQueue.sync { bsdConnections[peerId] }
        
        guard nwConnection != nil || bsdChannel != nil else {
            print("InputNetworkService: No connection found for peer \(peerId)")
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
            
            if let connection = nwConnection {
                connection.send(content: framedData, completion: .contentProcessed { [weak self] error in
                    if let error = error {
                        print("InputNetworkService: Send error: \(error)")
                        self?.delegate?.inputNetwork(self!, connectionError: error, for: peerId)
                    }
                })
            } else if let channel = bsdChannel {
                sendViaBSD(data: data, channel: channel)
            }
            
        } catch {
            print("InputNetworkService: Serialization error: \(error)")
        }
    }
    
    /// Send multiple events in a batch
    func send(_ events: [InputEvent], to peerId: UUID) {
        guard !events.isEmpty else { return }
        
        // Check for NWConnection first, then BSD connection
        let nwConnection = connectionQueue.sync { connections[peerId] }
        let bsdChannel = connectionQueue.sync { bsdConnections[peerId] }
        
        guard nwConnection != nil || bsdChannel != nil else {
            print("InputNetworkService: No connection found for peer \(peerId) (batch)")
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
            
            if let connection = nwConnection {
                connection.send(content: framedData, completion: .contentProcessed { [weak self] error in
                    if let error = error {
                        print("InputNetworkService: Batch send error: \(error)")
                        self?.delegate?.inputNetwork(self!, connectionError: error, for: peerId)
                    }
                })
            } else if let channel = bsdChannel {
                sendViaBSD(data: data, channel: channel)
            }
            
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
            print("InputNetworkService: Listener ready (IPv4)")
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
