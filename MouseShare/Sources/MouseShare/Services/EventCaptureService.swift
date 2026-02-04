import Foundation
import CoreGraphics
import Cocoa

// MARK: - Event Capture Delegate

protocol EventCaptureDelegate: AnyObject {
    func eventCapture(_ service: EventCaptureService, didCapture event: InputEvent)
    func eventCapture(_ service: EventCaptureService, mouseReachedEdge edge: ScreenEdge, at point: CGPoint)
    func eventCaptureDidRequestEscapeToLocal(_ service: EventCaptureService)
}

// MARK: - Escape Key Constants

private let kVKEscape: UInt16 = 53

// MARK: - Event Capture Service

/// Captures global mouse and keyboard events using CGEventTap
/// Requires Accessibility permissions
final class EventCaptureService {
    
    // MARK: - Properties
    
    weak var delegate: EventCaptureDelegate?
    
    fileprivate var eventTap: CFMachPort?
    private var runLoopSource: CFRunLoopSource?
    private var isCapturing = false
    private var isControlling = false  // True when we're in control (not sending to remote)
    
    // Screen bounds for edge detection
    private var screenBounds: CGRect = .zero
    private var edgeThreshold: CGFloat = 1
    private var cornerDeadZone: CGFloat = 10
    
    // Track modifier state
    private var currentModifiers: ModifierFlags = []
    
    // Track last mouse position for delta calculation
    private var lastMousePosition: CGPoint = .zero
    
    // MARK: - Initialization
    
    init() {
        updateScreenBounds()
        
        // Listen for screen configuration changes
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(screenConfigurationChanged),
            name: NSApplication.didChangeScreenParametersNotification,
            object: nil
        )
    }
    
    deinit {
        stop()
        NotificationCenter.default.removeObserver(self)
    }
    
    // MARK: - Public Methods
    
    /// Check if accessibility permissions are granted
    static var hasAccessibilityPermission: Bool {
        AXIsProcessTrusted()
    }
    
    /// Request accessibility permissions (shows system dialog)
    static func requestAccessibilityPermission() -> Bool {
        let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
        return AXIsProcessTrustedWithOptions(options)
    }
    
    /// Start capturing input events
    func start() -> Bool {
        guard !isCapturing else { return true }
        guard Self.hasAccessibilityPermission else {
            print("EventCaptureService: Accessibility permission not granted")
            return false
        }
        
        // Create event mask for all events we want to capture
        var eventMask: CGEventMask = 0
        eventMask |= (1 << CGEventType.mouseMoved.rawValue)
        eventMask |= (1 << CGEventType.leftMouseDown.rawValue)
        eventMask |= (1 << CGEventType.leftMouseUp.rawValue)
        eventMask |= (1 << CGEventType.rightMouseDown.rawValue)
        eventMask |= (1 << CGEventType.rightMouseUp.rawValue)
        eventMask |= (1 << CGEventType.leftMouseDragged.rawValue)
        eventMask |= (1 << CGEventType.rightMouseDragged.rawValue)
        eventMask |= (1 << CGEventType.otherMouseDown.rawValue)
        eventMask |= (1 << CGEventType.otherMouseUp.rawValue)
        eventMask |= (1 << CGEventType.otherMouseDragged.rawValue)
        eventMask |= (1 << CGEventType.scrollWheel.rawValue)
        eventMask |= (1 << CGEventType.keyDown.rawValue)
        eventMask |= (1 << CGEventType.keyUp.rawValue)
        eventMask |= (1 << CGEventType.flagsChanged.rawValue)
        
        // Create the event tap
        // Using a Unretained pointer to self for the callback
        let userInfo = Unmanaged.passUnretained(self).toOpaque()
        
        guard let tap = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .defaultTap,
            eventsOfInterest: eventMask,
            callback: eventTapCallback,
            userInfo: userInfo
        ) else {
            print("EventCaptureService: Failed to create event tap")
            return false
        }
        
        eventTap = tap
        
        // Create run loop source and add to current run loop
        runLoopSource = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
        CFRunLoopAddSource(CFRunLoopGetCurrent(), runLoopSource, .commonModes)
        
        // Enable the tap
        CGEvent.tapEnable(tap: tap, enable: true)
        
        isCapturing = true
        isControlling = true  // Start in control
        
        print("EventCaptureService: Started capturing events")
        return true
    }
    
    /// Stop capturing input events
    func stop() {
        guard isCapturing else { return }
        
        if let tap = eventTap {
            CGEvent.tapEnable(tap: tap, enable: false)
        }
        
        if let source = runLoopSource {
            CFRunLoopRemoveSource(CFRunLoopGetCurrent(), source, .commonModes)
        }
        
        eventTap = nil
        runLoopSource = nil
        isCapturing = false
        
        print("EventCaptureService: Stopped capturing events")
    }
    
    /// Set whether we're currently in control (events are local) or controlling remote
    func setControlling(_ controlling: Bool) {
        isControlling = controlling
    }
    
    /// Update screen bounds configuration
    func updateScreenBounds() {
        screenBounds = DisplayInfo.combinedBounds
        print("EventCaptureService: Screen bounds updated to \(screenBounds)")
    }
    
    func setEdgeThreshold(_ threshold: CGFloat) {
        edgeThreshold = threshold
    }
    
    func setCornerDeadZone(_ deadZone: CGFloat) {
        cornerDeadZone = deadZone
    }
    
    // MARK: - Private Methods
    
    @objc private func screenConfigurationChanged() {
        updateScreenBounds()
    }
    
    /// Process a captured CGEvent and convert to InputEvent
    fileprivate func processEvent(_ event: CGEvent, type: CGEventType) -> CGEvent? {
        let location = event.location
        lastMousePosition = location
        
        // SAFETY: Check for escape key - this ALWAYS returns to local control
        // Works even when controlling a remote machine (when isControlling is false)
        // Escape key or Cmd+Escape will abort the remote control session
        if type == .keyDown {
            let keyCode = UInt16(event.getIntegerValueField(.keyboardEventKeycode))
            
            if keyCode == kVKEscape {
                // When controlling remote (!isControlling means we're sending to remote),
                // Escape key should return to local control
                if !isControlling {
                    delegate?.eventCaptureDidRequestEscapeToLocal(self)
                    return nil  // Suppress the escape key
                }
            }
        }
        
        // Check for screen edge
        if type == .mouseMoved || type == .leftMouseDragged || type == .rightMouseDragged {
            checkScreenEdge(at: location)
        }
        
        // If we're in control (not sending to remote), pass events through
        if isControlling {
            return event
        }
        
        // Convert to InputEvent and notify delegate
        if let inputEvent = convertToInputEvent(event, type: type) {
            delegate?.eventCapture(self, didCapture: inputEvent)
        }
        
        // When controlling remote, suppress local events (return nil)
        // For keyboard events, we suppress; for mouse, we might want to show cursor
        switch type {
        case .keyDown, .keyUp, .flagsChanged:
            return nil  // Suppress keyboard events
        default:
            return nil  // Suppress mouse events too when controlling remote
        }
    }
    
    private func checkScreenEdge(at point: CGPoint) {
        guard isControlling else { return }  // Only check when we're in local control
        
        // Check if in corner dead zone
        let inCorner = (point.x < screenBounds.minX + cornerDeadZone || point.x > screenBounds.maxX - cornerDeadZone) &&
                       (point.y < screenBounds.minY + cornerDeadZone || point.y > screenBounds.maxY - cornerDeadZone)
        
        if inCorner { return }
        
        // Check each edge
        if point.x <= screenBounds.minX + edgeThreshold {
            delegate?.eventCapture(self, mouseReachedEdge: .left, at: point)
        } else if point.x >= screenBounds.maxX - edgeThreshold {
            delegate?.eventCapture(self, mouseReachedEdge: .right, at: point)
        } else if point.y <= screenBounds.minY + edgeThreshold {
            // Note: macOS has flipped Y coordinates for screen space
            delegate?.eventCapture(self, mouseReachedEdge: .top, at: point)
        } else if point.y >= screenBounds.maxY - edgeThreshold {
            delegate?.eventCapture(self, mouseReachedEdge: .bottom, at: point)
        }
    }
    
    private func convertToInputEvent(_ event: CGEvent, type: CGEventType) -> InputEvent? {
        let location = event.location
        let x = Float(location.x)
        let y = Float(location.y)
        
        switch type {
        case .mouseMoved:
            // Get mouse deltas for relative movement
            let deltaX = Float(event.getDoubleValueField(.mouseEventDeltaX))
            let deltaY = Float(event.getDoubleValueField(.mouseEventDeltaY))
            return .mouseMove(x: x, y: y, deltaX: deltaX, deltaY: deltaY, modifiers: currentModifiers)
            
        case .leftMouseDown:
            let clickCount = UInt8(event.getIntegerValueField(.mouseEventClickState))
            return .mouseDown(x: x, y: y, button: .left, clickCount: clickCount)
            
        case .leftMouseUp:
            return .mouseUp(x: x, y: y, button: .left)
            
        case .rightMouseDown:
            let clickCount = UInt8(event.getIntegerValueField(.mouseEventClickState))
            return .mouseDown(x: x, y: y, button: .right, clickCount: clickCount)
            
        case .rightMouseUp:
            return .mouseUp(x: x, y: y, button: .right)
            
        case .otherMouseDown:
            let clickCount = UInt8(event.getIntegerValueField(.mouseEventClickState))
            return .mouseDown(x: x, y: y, button: .center, clickCount: clickCount)
            
        case .otherMouseUp:
            return .mouseUp(x: x, y: y, button: .center)
            
        case .leftMouseDragged:
            return .mouseDrag(x: x, y: y, button: .left)
            
        case .rightMouseDragged:
            return .mouseDrag(x: x, y: y, button: .right)
            
        case .otherMouseDragged:
            return .mouseDrag(x: x, y: y, button: .center)
            
        case .scrollWheel:
            let deltaX = Float(event.getDoubleValueField(.scrollWheelEventDeltaAxis2))
            let deltaY = Float(event.getDoubleValueField(.scrollWheelEventDeltaAxis1))
            return .scroll(deltaX: deltaX, deltaY: deltaY, x: x, y: y)
            
        case .keyDown:
            let keyCode = UInt16(event.getIntegerValueField(.keyboardEventKeycode))
            let chars = keyCharacters(from: event)
            return .keyDown(keyCode: keyCode, characters: chars, modifiers: currentModifiers)
            
        case .keyUp:
            let keyCode = UInt16(event.getIntegerValueField(.keyboardEventKeycode))
            return .keyUp(keyCode: keyCode, modifiers: currentModifiers)
            
        case .flagsChanged:
            currentModifiers = ModifierFlags(from: event.flags)
            return .flagsChanged(modifiers: currentModifiers)
            
        default:
            return nil
        }
    }
    
    private func keyCharacters(from event: CGEvent) -> String? {
        // Try to get the characters from the event
        if let nsEvent = NSEvent(cgEvent: event) {
            return nsEvent.characters
        }
        return nil
    }
}

// MARK: - Event Tap Callback

/// Global callback function for the event tap
private func eventTapCallback(
    proxy: CGEventTapProxy,
    type: CGEventType,
    event: CGEvent,
    userInfo: UnsafeMutableRawPointer?
) -> Unmanaged<CGEvent>? {
    
    // Handle special events
    guard type != .tapDisabledByTimeout && type != .tapDisabledByUserInput else {
        // Re-enable the tap if it was disabled
        if let userInfo = userInfo {
            let service = Unmanaged<EventCaptureService>.fromOpaque(userInfo).takeUnretainedValue()
            if let tap = service.eventTap {
                CGEvent.tapEnable(tap: tap, enable: true)
            }
        }
        return Unmanaged.passUnretained(event)
    }
    
    guard let userInfo = userInfo else {
        return Unmanaged.passUnretained(event)
    }
    
    let service = Unmanaged<EventCaptureService>.fromOpaque(userInfo).takeUnretainedValue()
    
    if let processedEvent = service.processEvent(event, type: type) {
        return Unmanaged.passUnretained(processedEvent)
    }
    
    return nil  // Suppress the event
}
