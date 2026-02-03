import Foundation
import AppKit

// MARK: - Screen Configuration

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
    
    init() {
        self.edgeLinks = []
        self.edgeThreshold = 1
        self.transitionDelay = 0.0
        self.cornerDeadZone = 10
    }
    
    func peerForEdge(_ edge: ScreenEdge) -> UUID? {
        edgeLinks.first { $0.edge == edge && $0.enabled }?.peerId
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
        guard !displays.isEmpty else { return .zero }
        
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
        
        return CGRect(x: minX, y: minY, width: maxX - minX, height: maxY - minY)
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
