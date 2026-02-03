import Foundation
import CoreGraphics
import Cocoa

// MARK: - Screen Edge Delegate

protocol ScreenEdgeDelegate: AnyObject {
    func screenEdge(_ service: ScreenEdgeService, shouldTransitionAt edge: ScreenEdge, position: CGFloat) -> Bool
    func screenEdge(_ service: ScreenEdgeService, didTransitionTo edge: ScreenEdge, position: CGFloat)
    func screenEdge(_ service: ScreenEdgeService, didReturnFrom edge: ScreenEdge)
}

// MARK: - Screen Edge Service

/// Monitors mouse position at screen edges and handles screen transitions
final class ScreenEdgeService {
    
    // MARK: - Properties
    
    weak var delegate: ScreenEdgeDelegate?
    
    private var displayMonitor: Any?
    private var screenBounds: CGRect = .zero
    private var displays: [DisplayInfo] = []
    
    // Edge configuration
    var edgeThreshold: CGFloat = 1
    var cornerDeadZone: CGFloat = 10
    var transitionDelay: TimeInterval = 0.0
    
    // Transition state
    private var pendingTransition: ScreenEdge?
    private var transitionTimer: Timer?
    private var lastEdgeTime: Date?
    private var currentEdge: ScreenEdge?
    private var isTransitioned = false  // True when control has moved to another screen
    
    // MARK: - Initialization
    
    init() {
        updateDisplayConfiguration()
        setupDisplayChangeMonitoring()
    }
    
    deinit {
        transitionTimer?.invalidate()
        if let monitor = displayMonitor {
            NotificationCenter.default.removeObserver(monitor)
        }
    }
    
    // MARK: - Public Methods
    
    /// Update display configuration
    func updateDisplayConfiguration() {
        displays = DisplayInfo.allDisplays()
        screenBounds = DisplayInfo.combinedBounds
        
        print("ScreenEdgeService: Updated configuration")
        print("  Displays: \(displays.count)")
        print("  Combined bounds: \(screenBounds)")
        
        for display in displays {
            print("  - \(display.name): \(display.frame)")
        }
    }
    
    /// Check if a point is at a screen edge
    func checkEdge(at point: CGPoint) -> ScreenEdge? {
        // Check if in corner dead zone
        if isInCornerDeadZone(point) {
            cancelPendingTransition()
            return nil
        }
        
        // Check each edge
        if point.x <= screenBounds.minX + edgeThreshold {
            return .left
        } else if point.x >= screenBounds.maxX - edgeThreshold {
            return .right
        } else if point.y <= screenBounds.minY + edgeThreshold {
            return .top
        } else if point.y >= screenBounds.maxY - edgeThreshold {
            return .bottom
        }
        
        return nil
    }
    
    /// Process mouse position and handle edge transitions
    func processMousePosition(_ point: CGPoint) {
        // If already transitioned, check for return
        if isTransitioned {
            if let currentEdge = currentEdge {
                // Check if mouse is coming back
                if !isAtEdge(point, edge: currentEdge) {
                    // Not at the edge anymore while transitioned - might be returning
                }
            }
            return
        }
        
        // Check for edge
        guard let edge = checkEdge(at: point) else {
            cancelPendingTransition()
            return
        }
        
        // Calculate relative position along the edge
        let relativePosition = calculateRelativePosition(point: point, edge: edge)
        
        // Check if we should transition
        if pendingTransition == edge {
            // Already at this edge, check delay
            if let lastTime = lastEdgeTime {
                let elapsed = Date().timeIntervalSince(lastTime)
                if elapsed >= transitionDelay {
                    // Ask delegate if we should transition
                    if delegate?.screenEdge(self, shouldTransitionAt: edge, position: relativePosition) ?? false {
                        performTransition(to: edge, position: relativePosition)
                    }
                }
            }
        } else {
            // New edge, start timer
            startEdgeTimer(for: edge)
        }
    }
    
    /// Handle return from another screen (called when remote releases control)
    func handleReturn(from edge: ScreenEdge, at relativePosition: CGFloat) {
        guard isTransitioned else { return }
        
        isTransitioned = false
        currentEdge = nil
        
        // Calculate entry point
        let entryPoint = calculateEntryPoint(edge: edge, relativePosition: relativePosition)
        
        // Move cursor to entry point (this will be done by EventInjectionService)
        delegate?.screenEdge(self, didReturnFrom: edge)
        
        print("ScreenEdgeService: Returned from \(edge.displayName) at position \(relativePosition)")
    }
    
    /// Reset transition state (e.g., when disconnecting)
    func resetTransitionState() {
        cancelPendingTransition()
        isTransitioned = false
        currentEdge = nil
    }
    
    /// Get the display containing a point
    func display(containing point: CGPoint) -> DisplayInfo? {
        displays.first { $0.frame.contains(point) }
    }
    
    /// Calculate entry point when control returns
    func calculateEntryPoint(edge: ScreenEdge, relativePosition: CGFloat) -> CGPoint {
        let inset: CGFloat = 5  // Pixels from edge
        
        switch edge {
        case .left:
            let y = screenBounds.minY + relativePosition * screenBounds.height
            return CGPoint(x: screenBounds.minX + inset, y: y)
            
        case .right:
            let y = screenBounds.minY + relativePosition * screenBounds.height
            return CGPoint(x: screenBounds.maxX - inset, y: y)
            
        case .top:
            let x = screenBounds.minX + relativePosition * screenBounds.width
            return CGPoint(x: x, y: screenBounds.minY + inset)
            
        case .bottom:
            let x = screenBounds.minX + relativePosition * screenBounds.width
            return CGPoint(x: x, y: screenBounds.maxY - inset)
        }
    }
    
    // MARK: - Private Methods
    
    private func setupDisplayChangeMonitoring() {
        displayMonitor = NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            self?.updateDisplayConfiguration()
        }
    }
    
    private func isInCornerDeadZone(_ point: CGPoint) -> Bool {
        let nearLeftOrRight = point.x < screenBounds.minX + cornerDeadZone || 
                              point.x > screenBounds.maxX - cornerDeadZone
        let nearTopOrBottom = point.y < screenBounds.minY + cornerDeadZone || 
                              point.y > screenBounds.maxY - cornerDeadZone
        
        return nearLeftOrRight && nearTopOrBottom
    }
    
    private func isAtEdge(_ point: CGPoint, edge: ScreenEdge) -> Bool {
        switch edge {
        case .left:
            return point.x <= screenBounds.minX + edgeThreshold
        case .right:
            return point.x >= screenBounds.maxX - edgeThreshold
        case .top:
            return point.y <= screenBounds.minY + edgeThreshold
        case .bottom:
            return point.y >= screenBounds.maxY - edgeThreshold
        }
    }
    
    private func calculateRelativePosition(point: CGPoint, edge: ScreenEdge) -> CGFloat {
        switch edge {
        case .left, .right:
            // Relative Y position (0 = top, 1 = bottom)
            return (point.y - screenBounds.minY) / screenBounds.height
        case .top, .bottom:
            // Relative X position (0 = left, 1 = right)
            return (point.x - screenBounds.minX) / screenBounds.width
        }
    }
    
    private func startEdgeTimer(for edge: ScreenEdge) {
        cancelPendingTransition()
        
        pendingTransition = edge
        lastEdgeTime = Date()
        
        // If no delay, we'll transition on next position update
        if transitionDelay > 0 {
            transitionTimer = Timer.scheduledTimer(withTimeInterval: transitionDelay, repeats: false) { [weak self] _ in
                // Timer fired, transition will happen on next position check
            }
        }
    }
    
    private func cancelPendingTransition() {
        transitionTimer?.invalidate()
        transitionTimer = nil
        pendingTransition = nil
        lastEdgeTime = nil
    }
    
    private func performTransition(to edge: ScreenEdge, position: CGFloat) {
        cancelPendingTransition()
        
        isTransitioned = true
        currentEdge = edge
        
        delegate?.screenEdge(self, didTransitionTo: edge, position: position)
        
        print("ScreenEdgeService: Transitioned to \(edge.displayName) at position \(position)")
    }
}

// MARK: - Multi-Display Edge Detection

extension ScreenEdgeService {
    
    /// Check if a point is at an external edge (not between displays)
    func isExternalEdge(_ point: CGPoint, edge: ScreenEdge) -> Bool {
        guard let currentDisplay = display(containing: point) else {
            return false
        }
        
        // Check if there's another display in the direction of the edge
        for display in displays where display.id != currentDisplay.id {
            switch edge {
            case .left:
                // Check if there's a display to the left
                if display.frame.maxX == currentDisplay.frame.minX &&
                   point.y >= display.frame.minY && point.y <= display.frame.maxY {
                    return false  // Internal edge between displays
                }
            case .right:
                if display.frame.minX == currentDisplay.frame.maxX &&
                   point.y >= display.frame.minY && point.y <= display.frame.maxY {
                    return false
                }
            case .top:
                if display.frame.maxY == currentDisplay.frame.minY &&
                   point.x >= display.frame.minX && point.x <= display.frame.maxX {
                    return false
                }
            case .bottom:
                if display.frame.minY == currentDisplay.frame.maxY &&
                   point.x >= display.frame.minX && point.x <= display.frame.maxX {
                    return false
                }
            }
        }
        
        return true  // External edge
    }
}
