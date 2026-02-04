import Foundation
import CoreGraphics

// MARK: - Input Event Types

/// Represents all types of input events that can be transmitted between peers
enum InputEventType: UInt8, Codable {
    case mouseMove = 1
    case mouseDown = 2
    case mouseUp = 3
    case mouseDrag = 4
    case scrollWheel = 5
    case keyDown = 6
    case keyUp = 7
    case flagsChanged = 8  // Modifier keys
    case clipboardUpdate = 9
    case screenEnter = 10
    case screenLeave = 11
    case heartbeat = 12
    case screenEnterAck = 13  // Acknowledgment that screen enter was received
}

/// Mouse button identifiers
enum MouseButton: UInt8, Codable {
    case left = 0
    case right = 1
    case center = 2
    case other = 3
}

/// Keyboard modifier flags (matches CGEventFlags)
struct ModifierFlags: OptionSet, Codable {
    let rawValue: UInt64
    
    static let shift = ModifierFlags(rawValue: 1 << 0)
    static let control = ModifierFlags(rawValue: 1 << 1)
    static let option = ModifierFlags(rawValue: 1 << 2)
    static let command = ModifierFlags(rawValue: 1 << 3)
    static let capsLock = ModifierFlags(rawValue: 1 << 4)
    static let function = ModifierFlags(rawValue: 1 << 5)
    
    init(rawValue: UInt64) {
        self.rawValue = rawValue
    }
    
    init(from cgFlags: CGEventFlags) {
        var flags: ModifierFlags = []
        if cgFlags.contains(.maskShift) { flags.insert(.shift) }
        if cgFlags.contains(.maskControl) { flags.insert(.control) }
        if cgFlags.contains(.maskAlternate) { flags.insert(.option) }
        if cgFlags.contains(.maskCommand) { flags.insert(.command) }
        if cgFlags.contains(.maskAlphaShift) { flags.insert(.capsLock) }
        if cgFlags.contains(.maskSecondaryFn) { flags.insert(.function) }
        self = flags
    }
    
    var cgEventFlags: CGEventFlags {
        var flags: CGEventFlags = []
        if contains(.shift) { flags.insert(.maskShift) }
        if contains(.control) { flags.insert(.maskControl) }
        if contains(.option) { flags.insert(.maskAlternate) }
        if contains(.command) { flags.insert(.maskCommand) }
        if contains(.capsLock) { flags.insert(.maskAlphaShift) }
        if contains(.function) { flags.insert(.maskSecondaryFn) }
        return flags
    }
}

// MARK: - Main Input Event Structure

/// A single input event to be transmitted over the network
/// Designed for minimal size and fast serialization
struct InputEvent: Codable {
    let type: InputEventType
    let timestamp: UInt64  // Microseconds since epoch
    
    // Mouse data
    var x: Float?
    var y: Float?
    var deltaX: Float?
    var deltaY: Float?
    var button: MouseButton?
    var clickCount: UInt8?
    var scrollDeltaX: Float?
    var scrollDeltaY: Float?
    
    // Mouse delta for relative movement (when controlling remote)
    var mouseDeltaX: Float?
    var mouseDeltaY: Float?
    
    // Keyboard data
    var keyCode: UInt16?
    var characters: String?
    var modifiers: ModifierFlags?
    
    // Clipboard data
    var clipboardData: Data?
    var clipboardType: String?
    
    // Screen transition data
    var screenEdge: ScreenEdge?
    var entryX: Float?
    var entryY: Float?
    
    // MARK: - Factory Methods
    
    static func mouseMove(x: Float, y: Float, deltaX: Float = 0, deltaY: Float = 0, modifiers: ModifierFlags = []) -> InputEvent {
        var event = InputEvent(
            type: .mouseMove,
            timestamp: currentTimestamp(),
            x: x,
            y: y,
            modifiers: modifiers
        )
        event.mouseDeltaX = deltaX
        event.mouseDeltaY = deltaY
        return event
    }
    
    static func mouseDown(x: Float, y: Float, button: MouseButton, clickCount: UInt8 = 1) -> InputEvent {
        InputEvent(
            type: .mouseDown,
            timestamp: currentTimestamp(),
            x: x,
            y: y,
            button: button,
            clickCount: clickCount
        )
    }
    
    static func mouseUp(x: Float, y: Float, button: MouseButton) -> InputEvent {
        InputEvent(
            type: .mouseUp,
            timestamp: currentTimestamp(),
            x: x,
            y: y,
            button: button
        )
    }
    
    static func mouseDrag(x: Float, y: Float, button: MouseButton) -> InputEvent {
        InputEvent(
            type: .mouseDrag,
            timestamp: currentTimestamp(),
            x: x,
            y: y,
            button: button
        )
    }
    
    static func scroll(deltaX: Float, deltaY: Float, x: Float, y: Float) -> InputEvent {
        InputEvent(
            type: .scrollWheel,
            timestamp: currentTimestamp(),
            x: x,
            y: y,
            scrollDeltaX: deltaX,
            scrollDeltaY: deltaY
        )
    }
    
    static func keyDown(keyCode: UInt16, characters: String?, modifiers: ModifierFlags) -> InputEvent {
        InputEvent(
            type: .keyDown,
            timestamp: currentTimestamp(),
            keyCode: keyCode,
            characters: characters,
            modifiers: modifiers
        )
    }
    
    static func keyUp(keyCode: UInt16, modifiers: ModifierFlags) -> InputEvent {
        InputEvent(
            type: .keyUp,
            timestamp: currentTimestamp(),
            keyCode: keyCode,
            modifiers: modifiers
        )
    }
    
    static func flagsChanged(modifiers: ModifierFlags) -> InputEvent {
        InputEvent(
            type: .flagsChanged,
            timestamp: currentTimestamp(),
            modifiers: modifiers
        )
    }
    
    static func clipboardUpdate(data: Data, type: String) -> InputEvent {
        InputEvent(
            type: .clipboardUpdate,
            timestamp: currentTimestamp(),
            clipboardData: data,
            clipboardType: type
        )
    }
    
    static func screenEnter(edge: ScreenEdge, x: Float, y: Float) -> InputEvent {
        InputEvent(
            type: .screenEnter,
            timestamp: currentTimestamp(),
            screenEdge: edge,
            entryX: x,
            entryY: y
        )
    }
    
    static func screenLeave(edge: ScreenEdge) -> InputEvent {
        InputEvent(
            type: .screenLeave,
            timestamp: currentTimestamp(),
            screenEdge: edge
        )
    }
    
    static func heartbeat() -> InputEvent {
        InputEvent(
            type: .heartbeat,
            timestamp: currentTimestamp()
        )
    }
    
    static func screenEnterAck(edge: ScreenEdge) -> InputEvent {
        InputEvent(
            type: .screenEnterAck,
            timestamp: currentTimestamp(),
            screenEdge: edge
        )
    }
    
    private static func currentTimestamp() -> UInt64 {
        UInt64(Date().timeIntervalSince1970 * 1_000_000)
    }
}

// MARK: - Screen Edge

enum ScreenEdge: UInt8, Codable, CaseIterable {
    case left = 0
    case right = 1
    case top = 2
    case bottom = 3
    
    var opposite: ScreenEdge {
        switch self {
        case .left: return .right
        case .right: return .left
        case .top: return .bottom
        case .bottom: return .top
        }
    }
    
    var displayName: String {
        switch self {
        case .left: return "Left"
        case .right: return "Right"
        case .top: return "Top"
        case .bottom: return "Bottom"
        }
    }
}

// MARK: - Binary Serialization

extension InputEvent {
    /// Serialize to compact binary format for network transmission
    func serialize() throws -> Data {
        let encoder = JSONEncoder()
        return try encoder.encode(self)
    }
    
    /// Deserialize from binary format
    static func deserialize(from data: Data) throws -> InputEvent {
        let decoder = JSONDecoder()
        return try decoder.decode(InputEvent.self, from: data)
    }
}

// MARK: - Network Packet

/// A network packet containing one or more input events
struct InputPacket: Codable {
    let version: UInt8 = 1
    let events: [InputEvent]
    let sequenceNumber: UInt32
    
    func serialize() throws -> Data {
        let encoder = JSONEncoder()
        return try encoder.encode(self)
    }
    
    static func deserialize(from data: Data) throws -> InputPacket {
        let decoder = JSONDecoder()
        return try decoder.decode(InputPacket.self, from: data)
    }
}
