import Foundation
import Network

// MARK: - Peer Connection State

enum PeerConnectionState: String, Codable {
    case discovered
    case connecting
    case connected
    case controlling  // We are sending input to this peer
    case controlled   // This peer is sending input to us
    case disconnected
    case error
}

// MARK: - Peer Model

/// Represents a remote MouseShare peer on the network
final class Peer: Identifiable, ObservableObject, Equatable, Hashable {
    let id: UUID
    let name: String
    let hostName: String
    var endpoint: NWEndpoint?
    
    @Published var state: PeerConnectionState = .discovered
    @Published var lastSeen: Date = Date()
    @Published var latency: TimeInterval = 0  // Round-trip time in seconds
    @Published var screenPosition: ScreenEdge?  // Where this peer is relative to us
    
    // Connection stats
    @Published var bytesReceived: UInt64 = 0
    @Published var bytesSent: UInt64 = 0
    @Published var packetsDropped: UInt64 = 0
    
    // Screen info from remote peer
    @Published var remoteScreenWidth: Int = 1920
    @Published var remoteScreenHeight: Int = 1080
    
    init(id: UUID = UUID(), name: String, hostName: String, endpoint: NWEndpoint? = nil) {
        self.id = id
        self.name = name
        self.hostName = hostName
        self.endpoint = endpoint
    }
    
    // MARK: - Equatable & Hashable
    
    static func == (lhs: Peer, rhs: Peer) -> Bool {
        lhs.id == rhs.id
    }
    
    func hash(into hasher: inout Hasher) {
        hasher.combine(id)
    }
    
    // MARK: - Display Info
    
    var displayName: String {
        name.isEmpty ? hostName : name
    }
    
    var statusDescription: String {
        switch state {
        case .discovered: return "Discovered"
        case .connecting: return "Connecting..."
        case .connected: return "Connected"
        case .controlling: return "Controlling"
        case .controlled: return "Being Controlled"
        case .disconnected: return "Disconnected"
        case .error: return "Error"
        }
    }
    
    var isOnline: Bool {
        switch state {
        case .connected, .controlling, .controlled:
            return true
        default:
            return false
        }
    }
}

// MARK: - Peer Advertisement

/// Information broadcast to discover peers
struct PeerAdvertisement: Codable {
    let id: UUID
    let name: String
    let version: String
    let screenWidth: Int
    let screenHeight: Int
    let timestamp: Date
    
    static let serviceType = "_mouseshare._tcp"
    static let serviceDomain = "local."
    
    init(id: UUID, name: String, screenWidth: Int, screenHeight: Int) {
        self.id = id
        self.name = name
        self.version = "1.0"
        self.screenWidth = screenWidth
        self.screenHeight = screenHeight
        self.timestamp = Date()
    }
    
    var txtRecord: NWTXTRecord {
        var record = NWTXTRecord()
        record["id"] = id.uuidString
        record["name"] = name
        record["version"] = version
        record["width"] = String(screenWidth)
        record["height"] = String(screenHeight)
        return record
    }
    
    init?(from txtRecord: NWTXTRecord) {
        guard let idString = txtRecord["id"],
              let id = UUID(uuidString: idString),
              let name = txtRecord["name"],
              let version = txtRecord["version"],
              let widthStr = txtRecord["width"],
              let heightStr = txtRecord["height"],
              let width = Int(widthStr),
              let height = Int(heightStr) else {
            return nil
        }
        
        self.id = id
        self.name = name
        self.version = version
        self.screenWidth = width
        self.screenHeight = height
        self.timestamp = Date()
    }
}

// MARK: - Handshake Protocol

/// Initial handshake message when connecting to a peer
struct HandshakeRequest: Codable {
    let version: UInt8 = 1
    let peerId: UUID
    let peerName: String
    let screenWidth: Int
    let screenHeight: Int
    let encryptionEnabled: Bool
    let timestamp: UInt64
    
    func serialize() throws -> Data {
        try JSONEncoder().encode(self)
    }
    
    static func deserialize(from data: Data) throws -> HandshakeRequest {
        try JSONDecoder().decode(HandshakeRequest.self, from: data)
    }
}

/// Handshake response from peer
struct HandshakeResponse: Codable {
    let version: UInt8 = 1
    let accepted: Bool
    let peerId: UUID
    let peerName: String
    let screenWidth: Int
    let screenHeight: Int
    let errorMessage: String?
    
    func serialize() throws -> Data {
        try JSONEncoder().encode(self)
    }
    
    static func deserialize(from data: Data) throws -> HandshakeResponse {
        try JSONDecoder().decode(HandshakeResponse.self, from: data)
    }
}
