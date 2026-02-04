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
        debugLog("EventInjectionService initialized, bounds: \(localScreenBounds)")
    }
    
    private func debugLog(_ message: String) {
        let logPath = "/tmp/mouseshare_debug.log"
        let timestamp = ISO8601DateFormatter().string(from: Date())
        let line = "[\(timestamp)] [Injection] \(message)\n"
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
    
    // MARK: - Public Methods
    
    /// Update local screen bounds for coordinate mapping
    func updateLocalScreenBounds() {
        // Use CGDisplayBounds for consistency with CGWarpMouseCursorPosition
        let mainDisplay = CGMainDisplayID()
        localScreenBounds = CGDisplayBounds(mainDisplay)
        
        // Fallback if somehow bounds are invalid
        if localScreenBounds.width <= 0 || localScreenBounds.height <= 0 {
            localScreenBounds = CGRect(x: 0, y: 0, width: 1920, height: 1080)
        }
    }
    
    /// Set remote screen bounds for coordinate transformation
    func setRemoteScreenBounds(width: Int, height: Int) {
        remoteScreenBounds = CGRect(x: 0, y: 0, width: width, height: height)
    }
    
    /// Inject an input event into the system
    func inject(_ event: InputEvent) {
        debugLog("inject() called with event type: \(event.type)")
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
            debugLog("Handling screenEnter event")
            handleScreenEnter(event)
        default:
            debugLog("Unknown event type: \(event.type)")
            break
        }
    }
    
    /// Move mouse to a specific position (used for screen enter)
    func moveMouse(to point: CGPoint) {
        debugLog("moveMouse() called - moving cursor to \(point)")
        currentMousePosition = point
        
        // Ensure mouse is associated with cursor position (might have been disassociated)
        CGAssociateMouseAndMouseCursorPosition(1)
        
        // Warp the cursor
        let result = CGWarpMouseCursorPosition(point)
        debugLog("CGWarpMouseCursorPosition result: \(result), point: \(point)")
        
        // Verify the position after warp
        let actualPos = NSEvent.mouseLocation
        debugLog("Actual position after warp: \(actualPos)")
        
        // Optionally also post a mouse move event
        if let moveEvent = CGEvent(mouseEventSource: eventSource, mouseType: .mouseMoved,
                                   mouseCursorPosition: point, mouseButton: .left) {
            moveEvent.post(tap: .cghidEventTap)
            debugLog("Mouse move event posted")
        } else {
            debugLog("Failed to create mouse move event")
        }
    }
    
    /// Show or hide the cursor
    func setCursorVisible(_ visible: Bool) {
        debugLog("setCursorVisible(\(visible))")
        if visible {
            CGDisplayShowCursor(CGMainDisplayID())
        } else {
            CGDisplayHideCursor(CGMainDisplayID())
        }
    }
    
    /// Park cursor at center of screen (used when controlling remote to prevent drift)
    func parkCursor() {
        let mainDisplay = CGMainDisplayID()
        let bounds = CGDisplayBounds(mainDisplay)
        let center = CGPoint(x: bounds.midX, y: bounds.midY)
        debugLog("parkCursor() at \(center)")
        CGWarpMouseCursorPosition(center)
        currentMousePosition = center
    }
    
    /// Warp cursor to a specific screen edge (used when returning from remote control)
    /// - Parameters:
    ///   - edge: The edge to warp to
    ///   - relativePosition: Position along the edge (0.0 to 1.0, where 0.0 is top/left in CG coords)
    func warpToEdge(_ edge: ScreenEdge, relativePosition: CGFloat) {
        let mainDisplay = CGMainDisplayID()
        let bounds = CGDisplayBounds(mainDisplay)
        let inset: CGFloat = 50  // Stay inside the edge to avoid immediate re-trigger
        
        // Clamp relativePosition to valid range
        let clampedPosition = max(0.0, min(1.0, relativePosition))
        
        // Also clamp to avoid corners (10% buffer on each end)
        let safePosition = max(0.1, min(0.9, clampedPosition))
        
        var point: CGPoint
        switch edge {
        case .left:
            // Left edge: X at left, Y based on relative position
            point = CGPoint(x: bounds.minX + inset, y: bounds.minY + safePosition * bounds.height)
        case .right:
            // Right edge: X at right, Y based on relative position
            point = CGPoint(x: bounds.maxX - inset, y: bounds.minY + safePosition * bounds.height)
        case .top:
            // Top edge: Y at top (minY in CG coords), X based on relative position
            point = CGPoint(x: bounds.minX + safePosition * bounds.width, y: bounds.minY + inset)
        case .bottom:
            // Bottom edge: Y at bottom (maxY in CG coords), X based on relative position
            point = CGPoint(x: bounds.minX + safePosition * bounds.width, y: bounds.maxY - inset)
        }
        
        debugLog("warpToEdge(\(edge), \(relativePosition) -> \(safePosition)) -> \(point), bounds=\(bounds)")
        CGWarpMouseCursorPosition(point)
        currentMousePosition = point
    }
    
    /// Get the current cursor position (useful for calculating return position)
    func getCurrentPosition() -> CGPoint {
        if let locEvent = CGEvent(source: nil) {
            return locEvent.location
        }
        return currentMousePosition
    }
    
    // MARK: - Private Methods - Mouse Events
    
    private func injectMouseMove(_ event: InputEvent) {
        // ONLY use deltas for mouse movement - NEVER fall back to absolute coordinates
        // Absolute coordinates come from the remote machine and are meaningless here
        guard let deltaX = event.mouseDeltaX, let deltaY = event.mouseDeltaY else {
            // No deltas provided - this shouldn't happen for mouseMove events
            debugLog("injectMouseMove: no deltas provided, ignoring")
            return
        }
        
        // If no movement, don't do anything - prevents jumping from absolute coords
        if deltaX == 0 && deltaY == 0 {
            return
        }
        
        // Get the ACTUAL current cursor position using CGEvent (CG coordinates, top-left origin)
        let actualPosition: CGPoint
        if let locEvent = CGEvent(source: nil) {
            actualPosition = locEvent.location
        } else {
            actualPosition = currentMousePosition
        }
        
        // Apply delta to actual position
        let newX = actualPosition.x + CGFloat(deltaX)
        let newY = actualPosition.y + CGFloat(deltaY)
        
        // Clamp to screen bounds (use main display bounds for CG coordinates)
        let mainDisplay = CGMainDisplayID()
        let bounds = CGDisplayBounds(mainDisplay)
        let clampedX = max(bounds.minX, min(bounds.maxX - 1, newX))
        let clampedY = max(bounds.minY, min(bounds.maxY - 1, newY))
        
        let point = CGPoint(x: clampedX, y: clampedY)
        currentMousePosition = point
        
        // Warp cursor to new position
        CGWarpMouseCursorPosition(point)
        
        // Also post mouse move event for apps that need it
        if let cgEvent = CGEvent(
            mouseEventSource: eventSource,
            mouseType: .mouseMoved,
            mouseCursorPosition: point,
            mouseButton: .left
        ) {
            applyModifiers(to: cgEvent, from: event)
            cgEvent.post(tap: .cghidEventTap)
        }
    }
    
    private func injectMouseDown(_ event: InputEvent) {
        guard let button = event.button else { return }
        
        // Use the ACTUAL current cursor position, not remote coordinates
        let point = getCurrentPosition()
        
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
        guard let button = event.button else { return }
        
        // Use the ACTUAL current cursor position, not remote coordinates
        let point = getCurrentPosition()
        
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
        guard let button = event.button else { return }
        
        // Apply deltas for drag movement (similar to mouseMove)
        if let deltaX = event.mouseDeltaX, let deltaY = event.mouseDeltaY,
           (deltaX != 0 || deltaY != 0) {
            let actualPosition = getCurrentPosition()
            let newX = actualPosition.x + CGFloat(deltaX)
            let newY = actualPosition.y + CGFloat(deltaY)
            
            let mainDisplay = CGMainDisplayID()
            let bounds = CGDisplayBounds(mainDisplay)
            let clampedX = max(bounds.minX, min(bounds.maxX - 1, newX))
            let clampedY = max(bounds.minY, min(bounds.maxY - 1, newY))
            
            let point = CGPoint(x: clampedX, y: clampedY)
            currentMousePosition = point
            CGWarpMouseCursorPosition(point)
        }
        
        // Use the current cursor position for the drag event
        let point = getCurrentPosition()
        
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
        debugLog("handleScreenEnter: edge=\(String(describing: event.screenEdge)), entryX=\(String(describing: event.entryX)), entryY=\(String(describing: event.entryY))")
        guard let edge = event.screenEdge, let entryX = event.entryX, let entryY = event.entryY else {
            debugLog("handleScreenEnter: Missing required fields!")
            return
        }
        
        // Calculate entry position based on edge and relative position
        let entryPoint = calculateEntryPoint(edge: edge, relativeX: entryX, relativeY: entryY)
        debugLog("handleScreenEnter: calculated entryPoint=\(entryPoint)")
        
        // Move cursor to entry point
        moveMouse(to: entryPoint)
        
        // Show cursor
        setCursorVisible(true)
        debugLog("handleScreenEnter: complete")
    }
    
    private func calculateEntryPoint(edge: ScreenEdge, relativeX: Float, relativeY: Float) -> CGPoint {
        // Use CGDisplayBounds for consistency with CGWarpMouseCursorPosition
        let mainDisplay = CGMainDisplayID()
        let bounds = CGDisplayBounds(mainDisplay)
        
        // Clamp values to valid range
        let safeX = max(0.05, min(0.95, CGFloat(relativeX)))
        let safeY = max(0.05, min(0.95, CGFloat(relativeY)))
        
        let inset: CGFloat = 50  // Stay inside edge to avoid immediate re-trigger
        
        switch edge {
        case .left:
            // Entering from the left edge
            let y = bounds.minY + safeY * bounds.height
            return CGPoint(x: bounds.minX + inset, y: y)
            
        case .right:
            // Entering from the right edge
            let y = bounds.minY + safeY * bounds.height
            return CGPoint(x: bounds.maxX - inset, y: y)
            
        case .top:
            // Entering from the top edge (minY in CG coords)
            let x = bounds.minX + safeX * bounds.width
            return CGPoint(x: x, y: bounds.minY + inset)
            
        case .bottom:
            // Entering from the bottom edge (maxY in CG coords)
            let x = bounds.minX + safeX * bounds.width
            return CGPoint(x: x, y: bounds.maxY - inset)
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
