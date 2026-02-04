import Foundation
import AppKit

// MARK: - Screen Arrangement

/// Represents a positioned screen in the arrangement (local or remote)
struct ArrangedScreen: Codable, Identifiable, Equatable {
    let id: UUID  // For local screens, use display ID; for remote, use peer ID
    var name: String
    var width: Int
    var height: Int
    var x: Int  // Position in virtual coordinate space
    var y: Int  // Position in virtual coordinate space
    var isLocal: Bool
    var peerId: UUID?  // Only for remote screens
    
    init(id: UUID = UUID(), name: String, width: Int, height: Int, x: Int = 0, y: Int = 0, isLocal: Bool = true, peerId: UUID? = nil) {
        self.id = id
        self.name = name
        self.width = width
        self.height = height
        self.x = x
        self.y = y
        self.isLocal = isLocal
        self.peerId = peerId
    }
    
    var frame: CGRect {
        CGRect(x: x, y: y, width: width, height: height)
    }
    
    /// Check if this screen is adjacent to another on a given edge
    func adjacentEdge(to other: ArrangedScreen) -> ScreenEdge? {
        let tolerance = 50  // Allow some overlap tolerance
        
        // Check if vertically overlapping (for left/right adjacency)
        let verticalOverlap = max(0, min(y + height, other.y + other.height) - max(y, other.y))
        // Check if horizontally overlapping (for top/bottom adjacency)
        let horizontalOverlap = max(0, min(x + width, other.x + other.width) - max(x, other.x))
        
        // Right edge of self touches left edge of other
        if abs((x + width) - other.x) <= tolerance && verticalOverlap > tolerance {
            return .right
        }
        // Left edge of self touches right edge of other
        if abs(x - (other.x + other.width)) <= tolerance && verticalOverlap > tolerance {
            return .left
        }
        // Bottom edge of self touches top edge of other
        if abs((y + height) - other.y) <= tolerance && horizontalOverlap > tolerance {
            return .bottom
        }
        // Top edge of self touches bottom edge of other
        if abs(y - (other.y + other.height)) <= tolerance && horizontalOverlap > tolerance {
            return .top
        }
        
        return nil
    }
    
    /// Calculate the relative Y position on the adjacent edge (0.0 to 1.0)
    func relativePosition(at absoluteY: CGFloat, from edge: ScreenEdge) -> CGFloat {
        switch edge {
        case .left, .right:
            return (absoluteY - CGFloat(y)) / CGFloat(height)
        case .top, .bottom:
            return 0.5  // For now, center on top/bottom transitions
        }
    }
    
    /// Calculate the entry Y position on this screen given a relative position from another screen
    func entryPosition(relativePosition: CGFloat, on edge: ScreenEdge) -> CGFloat {
        switch edge {
        case .left, .right:
            return CGFloat(y) + relativePosition * CGFloat(height)
        case .top, .bottom:
            return CGFloat(x) + relativePosition * CGFloat(width)
        }
    }
}

/// Complete screen arrangement configuration
struct ScreenArrangement: Codable, Equatable {
    var screens: [ArrangedScreen]
    
    init() {
        self.screens = []
    }
    
    /// Get the local screen(s)
    var localScreens: [ArrangedScreen] {
        screens.filter { $0.isLocal }
    }
    
    /// Get remote peer screens
    var remoteScreens: [ArrangedScreen] {
        screens.filter { !$0.isLocal }
    }
    
    /// Find screen by peer ID
    func screen(forPeer peerId: UUID) -> ArrangedScreen? {
        screens.first { $0.peerId == peerId }
    }
    
    /// Find which remote screen is adjacent to a local screen on a given edge
    func remoteScreen(adjacentTo localScreen: ArrangedScreen, on edge: ScreenEdge) -> ArrangedScreen? {
        for screen in remoteScreens {
            if let adjacentEdge = localScreen.adjacentEdge(to: screen), adjacentEdge == edge {
                return screen
            }
        }
        return nil
    }
    
    /// Update or add a remote screen
    mutating func updateRemoteScreen(peerId: UUID, name: String, width: Int, height: Int) {
        // First check by peerId
        if let index = screens.firstIndex(where: { $0.peerId == peerId }) {
            screens[index].name = name
            screens[index].width = width
            screens[index].height = height
            return
        }
        
        // Also check by name to prevent duplicates from stale peer IDs
        if let index = screens.firstIndex(where: { !$0.isLocal && $0.name == name }) {
            screens[index].peerId = peerId
            screens[index].width = width
            screens[index].height = height
            return
        }
        
        // Add new remote screen, position it to the left of local screens
        let minX = screens.map { $0.x }.min() ?? 0
        let localHeight = screens.first(where: { $0.isLocal })?.height ?? height
        let newScreen = ArrangedScreen(
            id: UUID(),
            name: name,
            width: width,
            height: height,
            x: minX - width - 50,  // Position to the left
            y: 0,
            isLocal: false,
            peerId: peerId
        )
        screens.append(newScreen)
    }
    
    /// Remove all remote screens that aren't in the connected peers list
    mutating func removeStaleRemoteScreens(connectedPeerIds: [UUID]) {
        screens.removeAll { screen in
            !screen.isLocal && (screen.peerId == nil || !connectedPeerIds.contains(screen.peerId!))
        }
    }
    
    /// Remove duplicate screens (keep first occurrence)
    mutating func deduplicateScreens() {
        var seenNames = Set<String>()
        var seenPeerIds = Set<UUID>()
        
        screens = screens.filter { screen in
            // Always keep local screens, deduplicate by name
            if screen.isLocal {
                if seenNames.contains(screen.name) {
                    return false
                }
                seenNames.insert(screen.name)
                return true
            }
            
            // For remote screens, deduplicate by peerId or name
            if let peerId = screen.peerId {
                if seenPeerIds.contains(peerId) {
                    return false
                }
                seenPeerIds.insert(peerId)
            }
            if seenNames.contains(screen.name) {
                return false
            }
            seenNames.insert(screen.name)
            return true
        }
    }
    
    /// Update position of a screen
    mutating func updatePosition(id: UUID, x: Int, y: Int) {
        if let index = screens.firstIndex(where: { $0.id == id }) {
            screens[index].x = x
            screens[index].y = y
        }
    }
    
    /// Remove a remote screen
    mutating func removeRemoteScreen(peerId: UUID) {
        screens.removeAll { $0.peerId == peerId }
    }
    
    /// Initialize with local displays
    mutating func initializeLocalDisplays() {
        // Remove existing local screens
        screens.removeAll { $0.isLocal }
        
        // Add current displays
        let displays = DisplayInfo.allDisplays()
        for display in displays {
            let screen = ArrangedScreen(
                id: UUID(),
                name: display.name,
                width: display.width,
                height: display.height,
                x: Int(display.frame.origin.x),
                y: Int(display.frame.origin.y),
                isLocal: true,
                peerId: nil
            )
            screens.append(screen)
        }
    }
}

// MARK: - Screen Configuration (Legacy - kept for compatibility)

/// Configuration for screen edge linking between peers
struct ScreenEdgeLink: Codable, Identifiable, Equatable {
    let id: UUID
    let edge: ScreenEdge
    let peerId: UUID
    let peerEdge: ScreenEdge
    var enabled: Bool
    
    init(edge: ScreenEdge, peerId: UUID, peerEdge: ScreenEdge = .left, enabled: Bool = true) {
        self.id = UUID()
        self.edge = edge
        self.peerId = peerId
        self.peerEdge = peerEdge
        self.enabled = enabled
    }
}

/// Complete screen layout configuration
struct ScreenConfiguration: Codable, Equatable {
    var edgeLinks: [ScreenEdgeLink]
    var edgeThreshold: Int  // Pixels from edge to trigger transition
    var transitionDelay: TimeInterval  // Seconds to wait at edge before switching
    var cornerDeadZone: Int  // Pixels from corner that won't trigger transition
    var arrangement: ScreenArrangement  // New: visual arrangement
    
    init() {
        self.edgeLinks = []
        self.edgeThreshold = 1
        self.transitionDelay = 0.0
        self.cornerDeadZone = 10
        self.arrangement = ScreenArrangement()
    }
    
    func peerForEdge(_ edge: ScreenEdge) -> UUID? {
        // First check the visual arrangement
        for localScreen in arrangement.localScreens {
            if let remoteScreen = arrangement.remoteScreen(adjacentTo: localScreen, on: edge) {
                return remoteScreen.peerId
            }
        }
        // Fall back to legacy edge links
        return edgeLinks.first { $0.edge == edge && $0.enabled }?.peerId
    }
    
    mutating func setLink(edge: ScreenEdge, peerId: UUID, peerEdge: ScreenEdge = .left) {
        // Remove existing link for this edge
        edgeLinks.removeAll { $0.edge == edge }
        // Add new link
        edgeLinks.append(ScreenEdgeLink(edge: edge, peerId: peerId, peerEdge: peerEdge))
    }
    
    mutating func removeLink(edge: ScreenEdge) {
        edgeLinks.removeAll { $0.edge == edge }
    }
}

// MARK: - Display Information

/// Information about a physical display
struct DisplayInfo: Identifiable {
    let id: CGDirectDisplayID
    let frame: CGRect
    let isMain: Bool
    let name: String
    
    var width: Int { Int(frame.width) }
    var height: Int { Int(frame.height) }
    
    init(displayID: CGDirectDisplayID) {
        self.id = displayID
        self.frame = CGDisplayBounds(displayID)
        self.isMain = CGDisplayIsMain(displayID) != 0
        self.name = DisplayInfo.displayName(for: displayID)
    }
    
    private static func displayName(for displayID: CGDirectDisplayID) -> String {
        // Try to get the localized name from NSScreen
        for screen in NSScreen.screens {
            if let screenNumber = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? CGDirectDisplayID,
               screenNumber == displayID {
                return screen.localizedName
            }
        }
        return "Display \(displayID)"
    }
    
    /// Get all connected displays
    static func allDisplays() -> [DisplayInfo] {
        var displayCount: UInt32 = 0
        CGGetActiveDisplayList(0, nil, &displayCount)
        
        guard displayCount > 0 else { return [] }
        
        var displays = [CGDirectDisplayID](repeating: 0, count: Int(displayCount))
        CGGetActiveDisplayList(displayCount, &displays, &displayCount)
        
        return displays.map { DisplayInfo(displayID: $0) }
    }
    
    /// Get the main display
    static var mainDisplay: DisplayInfo? {
        allDisplays().first { $0.isMain }
    }
    
    /// Get combined bounds of all displays
    static var combinedBounds: CGRect {
        let displays = allDisplays()
        
        // Fallback to main display bounds if no displays detected
        if displays.isEmpty {
            let mainDisplay = CGMainDisplayID()
            let bounds = CGDisplayBounds(mainDisplay)
            // CGDisplayBounds should always return valid bounds for main display
            if bounds.width > 0 && bounds.height > 0 {
                return bounds
            }
            // Ultimate fallback - should never happen
            return CGRect(x: 0, y: 0, width: 1920, height: 1080)
        }
        
        var minX = CGFloat.infinity
        var minY = CGFloat.infinity
        var maxX = -CGFloat.infinity
        var maxY = -CGFloat.infinity
        
        for display in displays {
            minX = min(minX, display.frame.minX)
            minY = min(minY, display.frame.minY)
            maxX = max(maxX, display.frame.maxX)
            maxY = max(maxY, display.frame.maxY)
        }
        
        let result = CGRect(x: minX, y: minY, width: maxX - minX, height: maxY - minY)
        
        // Sanity check - if somehow we still got zero bounds, use main display
        if result.width <= 0 || result.height <= 0 {
            let mainDisplay = CGMainDisplayID()
            return CGDisplayBounds(mainDisplay)
        }
        
        return result
    }
}

// MARK: - App Settings

/// Application-wide settings
struct AppSettings: Codable, Equatable {
    var encryptionEnabled: Bool
    var encryptionPassword: String
    var clipboardSyncEnabled: Bool
    var autoConnectEnabled: Bool
    var showNotifications: Bool
    var launchAtLogin: Bool
    var hotkey: HotkeyConfig?
    var screenConfig: ScreenConfiguration
    
    init() {
        self.encryptionEnabled = false
        self.encryptionPassword = ""
        self.clipboardSyncEnabled = true
        self.autoConnectEnabled = true
        self.showNotifications = true
        self.launchAtLogin = false
        self.hotkey = nil
        self.screenConfig = ScreenConfiguration()
    }
    
    // MARK: - Persistence
    
    private static let settingsKey = "MouseShareSettings"
    
    static func load() -> AppSettings {
        guard let data = UserDefaults.standard.data(forKey: settingsKey),
              let settings = try? JSONDecoder().decode(AppSettings.self, from: data) else {
            return AppSettings()
        }
        return settings
    }
    
    func save() {
        if let data = try? JSONEncoder().encode(self) {
            UserDefaults.standard.set(data, forKey: AppSettings.settingsKey)
        }
    }
}

/// Hotkey configuration for manual control switching
struct HotkeyConfig: Codable, Equatable {
    var keyCode: UInt16
    var modifiers: ModifierFlags
    
    var displayString: String {
        var parts: [String] = []
        if modifiers.contains(.control) { parts.append("⌃") }
        if modifiers.contains(.option) { parts.append("⌥") }
        if modifiers.contains(.shift) { parts.append("⇧") }
        if modifiers.contains(.command) { parts.append("⌘") }
        parts.append(keyCodeToString(keyCode))
        return parts.joined()
    }
    
    private func keyCodeToString(_ keyCode: UInt16) -> String {
        // Common key codes
        switch keyCode {
        case 0: return "A"
        case 1: return "S"
        case 2: return "D"
        case 3: return "F"
        case 4: return "H"
        case 5: return "G"
        case 6: return "Z"
        case 7: return "X"
        case 8: return "C"
        case 9: return "V"
        case 11: return "B"
        case 12: return "Q"
        case 13: return "W"
        case 14: return "E"
        case 15: return "R"
        case 16: return "Y"
        case 17: return "T"
        case 31: return "O"
        case 32: return "U"
        case 34: return "I"
        case 35: return "P"
        case 37: return "L"
        case 38: return "J"
        case 40: return "K"
        case 45: return "N"
        case 46: return "M"
        case 49: return "Space"
        case 123: return "←"
        case 124: return "→"
        case 125: return "↓"
        case 126: return "↑"
        default: return "Key\(keyCode)"
        }
    }
}
