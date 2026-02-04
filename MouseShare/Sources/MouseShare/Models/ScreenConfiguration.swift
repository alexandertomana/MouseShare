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
        let tolerance = 100  // Increased tolerance for easier adjacency detection
        
        // Check if vertically overlapping (for left/right adjacency)
        let verticalOverlap = max(0, min(y + height, other.y + other.height) - max(y, other.y))
        // Check if horizontally overlapping (for top/bottom adjacency)
        let horizontalOverlap = max(0, min(x + width, other.x + other.width) - max(x, other.x))
        
        // Right edge of self touches left edge of other
        let rightGap = abs((x + width) - other.x)
        if rightGap <= tolerance && verticalOverlap > tolerance {
            return .right
        }
        // Left edge of self touches right edge of other
        let leftGap = abs(x - (other.x + other.width))
        if leftGap <= tolerance && verticalOverlap > tolerance {
            return .left
        }
        // Bottom edge of self touches top edge of other
        let bottomGap = abs((y + height) - other.y)
        if bottomGap <= tolerance && horizontalOverlap > tolerance {
            return .bottom
        }
        // Top edge of self touches bottom edge of other
        let topGap = abs(y - (other.y + other.height))
        if topGap <= tolerance && horizontalOverlap > tolerance {
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
    
    /// Calculate the entry point on the target screen based on the exit point from the source screen
    /// Takes into account the actual overlap region between screens
    /// - Parameters:
    ///   - exitPoint: The position (0.0-1.0) along the exit edge on the source screen
    ///   - sourceScreen: The screen being exited
    ///   - targetScreen: The screen being entered
    ///   - edge: The edge being crossed (from source screen's perspective)
    /// - Returns: The entry position (0.0-1.0) on the target screen's opposite edge
    func calculateEntryPosition(exitPoint: CGFloat, from sourceScreen: ArrangedScreen, to targetScreen: ArrangedScreen, edge: ScreenEdge) -> CGFloat {
        switch edge {
        case .left, .right:
            // Vertical overlap calculation
            // Find the overlapping Y range between the two screens
            let sourceTop = sourceScreen.y
            let sourceBottom = sourceScreen.y + sourceScreen.height
            let targetTop = targetScreen.y
            let targetBottom = targetScreen.y + targetScreen.height
            
            // Calculate overlap region
            let overlapTop = max(sourceTop, targetTop)
            let overlapBottom = min(sourceBottom, targetBottom)
            let overlapHeight = max(0, overlapBottom - overlapTop)
            
            guard overlapHeight > 0 else { return 0.5 }  // No overlap, center
            
            // Convert exitPoint (0-1 on source) to absolute Y
            let absoluteY = CGFloat(sourceTop) + exitPoint * CGFloat(sourceScreen.height)
            
            // Check if the exit point is within the overlap region
            if absoluteY < CGFloat(overlapTop) {
                // Exit point is above overlap - enter at top of overlap
                return CGFloat(overlapTop - targetTop) / CGFloat(targetScreen.height)
            } else if absoluteY > CGFloat(overlapBottom) {
                // Exit point is below overlap - enter at bottom of overlap
                return CGFloat(overlapBottom - targetTop) / CGFloat(targetScreen.height)
            } else {
                // Exit point is within overlap - map directly
                return (absoluteY - CGFloat(targetTop)) / CGFloat(targetScreen.height)
            }
            
        case .top, .bottom:
            // Horizontal overlap calculation
            let sourceLeft = sourceScreen.x
            let sourceRight = sourceScreen.x + sourceScreen.width
            let targetLeft = targetScreen.x
            let targetRight = targetScreen.x + targetScreen.width
            
            let overlapLeft = max(sourceLeft, targetLeft)
            let overlapRight = min(sourceRight, targetRight)
            let overlapWidth = max(0, overlapRight - overlapLeft)
            
            guard overlapWidth > 0 else { return 0.5 }
            
            let absoluteX = CGFloat(sourceLeft) + exitPoint * CGFloat(sourceScreen.width)
            
            if absoluteX < CGFloat(overlapLeft) {
                return CGFloat(overlapLeft - targetLeft) / CGFloat(targetScreen.width)
            } else if absoluteX > CGFloat(overlapRight) {
                return CGFloat(overlapRight - targetLeft) / CGFloat(targetScreen.width)
            } else {
                return (absoluteX - CGFloat(targetLeft)) / CGFloat(targetScreen.width)
            }
        }
    }
    
    /// Get local and remote screen pair for an edge transition
    func screenPair(forEdge edge: ScreenEdge) -> (local: ArrangedScreen, remote: ArrangedScreen)? {
        for localScreen in localScreens {
            if let remoteScreen = remoteScreen(adjacentTo: localScreen, on: edge) {
                return (localScreen, remoteScreen)
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
        
        // Add current displays - normalize positions so primary display is at (0,0)
        let displays = DisplayInfo.allDisplays()
        
        // Find the main display's position as origin
        let mainDisplay = displays.first { $0.isMain }
        let originX = Int(mainDisplay?.frame.origin.x ?? 0)
        let originY = Int(mainDisplay?.frame.origin.y ?? 0)
        
        for display in displays {
            let screen = ArrangedScreen(
                id: UUID(),
                name: display.name,
                width: display.width,
                height: display.height,
                x: Int(display.frame.origin.x) - originX,  // Normalize to (0,0)
                y: Int(display.frame.origin.y) - originY,
                isLocal: true,
                peerId: nil
            )
            screens.append(screen)
        }
    }
    
    /// Clear all arrangement data and start fresh
    mutating func clearAll() {
        screens.removeAll()
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
                debugLogConfig("peerForEdge(\(edge)): Found via arrangement - local=\(localScreen.name), remote=\(remoteScreen.name), peerId=\(String(describing: remoteScreen.peerId))")
                return remoteScreen.peerId
            }
        }
        // Fall back to legacy edge links
        if let link = edgeLinks.first(where: { $0.edge == edge && $0.enabled }) {
            debugLogConfig("peerForEdge(\(edge)): Found via legacy link - peerId=\(link.peerId)")
            return link.peerId
        }
        debugLogConfig("peerForEdge(\(edge)): No peer found. LocalScreens=\(arrangement.localScreens.count), RemoteScreens=\(arrangement.remoteScreens.count)")
        return nil
    }
    
    private func debugLogConfig(_ message: String) {
        let logPath = "/tmp/mouseshare_debug.log"
        let timestamp = ISO8601DateFormatter().string(from: Date())
        let line = "[\(timestamp)] [Config] \(message)\n"
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
