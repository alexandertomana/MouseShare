import Foundation
import CoreGraphics
import Cocoa

// MARK: - Event Injection Service

/// Injects mouse and keyboard events into the system
/// Used to replay events received from remote peers
final class EventInjectionService {
    
    // MARK: - Properties
    
    private var eventSource: CGEventSource?
    private var currentMousePosition: CGPoint = .zero
    private var currentModifiers: CGEventFlags = []
    
    // Screen mapping for coordinate transformation
    private var localScreenBounds: CGRect = .zero
    private var remoteScreenBounds: CGRect = .zero
    
    // MARK: - Initialization
    
    init() {
        // Create event source for posting events
        eventSource = CGEventSource(stateID: .combinedSessionState)
        updateLocalScreenBounds()
    }
    
    // MARK: - Public Methods
    
    /// Update local screen bounds for coordinate mapping
    func updateLocalScreenBounds() {
        localScreenBounds = DisplayInfo.combinedBounds
    }
    
    /// Set remote screen bounds for coordinate transformation
    func setRemoteScreenBounds(width: Int, height: Int) {
        remoteScreenBounds = CGRect(x: 0, y: 0, width: width, height: height)
    }
    
    /// Inject an input event into the system
    func inject(_ event: InputEvent) {
        switch event.type {
        case .mouseMove:
            injectMouseMove(event)
        case .mouseDown:
            injectMouseDown(event)
        case .mouseUp:
            injectMouseUp(event)
        case .mouseDrag:
            injectMouseDrag(event)
        case .scrollWheel:
            injectScroll(event)
        case .keyDown:
            injectKeyDown(event)
        case .keyUp:
            injectKeyUp(event)
        case .flagsChanged:
            injectFlagsChanged(event)
        case .screenEnter:
            handleScreenEnter(event)
        default:
            break
        }
    }
    
    /// Move mouse to a specific position (used for screen enter)
    func moveMouse(to point: CGPoint) {
        currentMousePosition = point
        CGWarpMouseCursorPosition(point)
        
        // Optionally also post a mouse move event
        if let moveEvent = CGEvent(mouseEventSource: eventSource, mouseType: .mouseMoved,
                                   mouseCursorPosition: point, mouseButton: .left) {
            moveEvent.post(tap: .cghidEventTap)
        }
    }
    
    /// Show or hide the cursor
    func setCursorVisible(_ visible: Bool) {
        if visible {
            CGDisplayShowCursor(CGMainDisplayID())
        } else {
            CGDisplayHideCursor(CGMainDisplayID())
        }
    }
    
    // MARK: - Private Methods - Mouse Events
    
    private func injectMouseMove(_ event: InputEvent) {
        guard let x = event.x, let y = event.y else { return }
        
        let point = transformCoordinates(x: x, y: y)
        currentMousePosition = point
        
        guard let cgEvent = CGEvent(
            mouseEventSource: eventSource,
            mouseType: .mouseMoved,
            mouseCursorPosition: point,
            mouseButton: .left
        ) else { return }
        
        applyModifiers(to: cgEvent, from: event)
        cgEvent.post(tap: .cghidEventTap)
    }
    
    private func injectMouseDown(_ event: InputEvent) {
        guard let x = event.x, let y = event.y, let button = event.button else { return }
        
        let point = transformCoordinates(x: x, y: y)
        currentMousePosition = point
        
        let (mouseType, cgButton) = mouseTypeAndButton(for: button, isDown: true)
        
        guard let cgEvent = CGEvent(
            mouseEventSource: eventSource,
            mouseType: mouseType,
            mouseCursorPosition: point,
            mouseButton: cgButton
        ) else { return }
        
        if let clickCount = event.clickCount {
            cgEvent.setIntegerValueField(.mouseEventClickState, value: Int64(clickCount))
        }
        
        applyModifiers(to: cgEvent, from: event)
        cgEvent.post(tap: .cghidEventTap)
    }
    
    private func injectMouseUp(_ event: InputEvent) {
        guard let x = event.x, let y = event.y, let button = event.button else { return }
        
        let point = transformCoordinates(x: x, y: y)
        currentMousePosition = point
        
        let (mouseType, cgButton) = mouseTypeAndButton(for: button, isDown: false)
        
        guard let cgEvent = CGEvent(
            mouseEventSource: eventSource,
            mouseType: mouseType,
            mouseCursorPosition: point,
            mouseButton: cgButton
        ) else { return }
        
        applyModifiers(to: cgEvent, from: event)
        cgEvent.post(tap: .cghidEventTap)
    }
    
    private func injectMouseDrag(_ event: InputEvent) {
        guard let x = event.x, let y = event.y, let button = event.button else { return }
        
        let point = transformCoordinates(x: x, y: y)
        currentMousePosition = point
        
        let mouseType: CGEventType
        switch button {
        case .left: mouseType = .leftMouseDragged
        case .right: mouseType = .rightMouseDragged
        default: mouseType = .otherMouseDragged
        }
        
        guard let cgEvent = CGEvent(
            mouseEventSource: eventSource,
            mouseType: mouseType,
            mouseCursorPosition: point,
            mouseButton: cgButton(for: button)
        ) else { return }
        
        applyModifiers(to: cgEvent, from: event)
        cgEvent.post(tap: .cghidEventTap)
    }
    
    private func injectScroll(_ event: InputEvent) {
        guard let deltaX = event.scrollDeltaX, let deltaY = event.scrollDeltaY else { return }
        
        guard let cgEvent = CGEvent(
            scrollWheelEvent2Source: eventSource,
            units: .pixel,
            wheelCount: 2,
            wheel1: Int32(deltaY),
            wheel2: Int32(deltaX),
            wheel3: 0
        ) else { return }
        
        cgEvent.post(tap: .cghidEventTap)
    }
    
    // MARK: - Private Methods - Keyboard Events
    
    private func injectKeyDown(_ event: InputEvent) {
        guard let keyCode = event.keyCode else { return }
        
        guard let cgEvent = CGEvent(
            keyboardEventSource: eventSource,
            virtualKey: keyCode,
            keyDown: true
        ) else { return }
        
        applyModifiers(to: cgEvent, from: event)
        cgEvent.post(tap: .cghidEventTap)
    }
    
    private func injectKeyUp(_ event: InputEvent) {
        guard let keyCode = event.keyCode else { return }
        
        guard let cgEvent = CGEvent(
            keyboardEventSource: eventSource,
            virtualKey: keyCode,
            keyDown: false
        ) else { return }
        
        applyModifiers(to: cgEvent, from: event)
        cgEvent.post(tap: .cghidEventTap)
    }
    
    private func injectFlagsChanged(_ event: InputEvent) {
        guard let modifiers = event.modifiers else { return }
        
        currentModifiers = modifiers.cgEventFlags
        
        // Create a flags changed event
        guard let cgEvent = CGEvent(keyboardEventSource: eventSource, virtualKey: 0, keyDown: true) else { return }
        cgEvent.type = .flagsChanged
        cgEvent.flags = currentModifiers
        cgEvent.post(tap: .cghidEventTap)
    }
    
    // MARK: - Private Methods - Screen Transition
    
    private func handleScreenEnter(_ event: InputEvent) {
        guard let edge = event.screenEdge, let entryX = event.entryX, let entryY = event.entryY else { return }
        
        // Calculate entry position based on edge and relative position
        let entryPoint = calculateEntryPoint(edge: edge, relativeX: entryX, relativeY: entryY)
        
        // Move cursor to entry point
        moveMouse(to: entryPoint)
        
        // Show cursor
        setCursorVisible(true)
    }
    
    private func calculateEntryPoint(edge: ScreenEdge, relativeX: Float, relativeY: Float) -> CGPoint {
        let bounds = localScreenBounds
        
        switch edge {
        case .left:
            // Entering from the left edge
            let y = bounds.minY + CGFloat(relativeY) * bounds.height
            return CGPoint(x: bounds.minX + 5, y: y)
            
        case .right:
            // Entering from the right edge
            let y = bounds.minY + CGFloat(relativeY) * bounds.height
            return CGPoint(x: bounds.maxX - 5, y: y)
            
        case .top:
            // Entering from the top edge
            let x = bounds.minX + CGFloat(relativeX) * bounds.width
            return CGPoint(x: x, y: bounds.minY + 5)
            
        case .bottom:
            // Entering from the bottom edge
            let x = bounds.minX + CGFloat(relativeX) * bounds.width
            return CGPoint(x: x, y: bounds.maxY - 5)
        }
    }
    
    // MARK: - Helper Methods
    
    private func transformCoordinates(x: Float, y: Float) -> CGPoint {
        // If remote bounds are set, transform coordinates proportionally
        if remoteScreenBounds.width > 0 && remoteScreenBounds.height > 0 {
            let normalizedX = CGFloat(x) / remoteScreenBounds.width
            let normalizedY = CGFloat(y) / remoteScreenBounds.height
            
            return CGPoint(
                x: localScreenBounds.minX + normalizedX * localScreenBounds.width,
                y: localScreenBounds.minY + normalizedY * localScreenBounds.height
            )
        }
        
        // Otherwise use absolute coordinates
        return CGPoint(x: CGFloat(x), y: CGFloat(y))
    }
    
    private func mouseTypeAndButton(for button: MouseButton, isDown: Bool) -> (CGEventType, CGMouseButton) {
        switch button {
        case .left:
            return (isDown ? .leftMouseDown : .leftMouseUp, .left)
        case .right:
            return (isDown ? .rightMouseDown : .rightMouseUp, .right)
        case .center, .other:
            return (isDown ? .otherMouseDown : .otherMouseUp, .center)
        }
    }
    
    private func cgButton(for button: MouseButton) -> CGMouseButton {
        switch button {
        case .left: return .left
        case .right: return .right
        case .center, .other: return .center
        }
    }
    
    private func applyModifiers(to cgEvent: CGEvent, from event: InputEvent) {
        if let modifiers = event.modifiers {
            cgEvent.flags = modifiers.cgEventFlags
        }
    }
}
