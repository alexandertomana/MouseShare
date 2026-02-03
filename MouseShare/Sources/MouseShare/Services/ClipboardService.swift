import Foundation
import Cocoa

// MARK: - Clipboard Delegate

protocol ClipboardDelegate: AnyObject {
    func clipboard(_ service: ClipboardService, didChange data: Data, type: String)
}

// MARK: - Clipboard Service

/// Monitors and synchronizes clipboard between peers
final class ClipboardService {
    
    // MARK: - Supported Types
    
    static let supportedTypes: [NSPasteboard.PasteboardType] = [
        .string,
        .rtf,
        .html,
        .png,
        .tiff,
        .pdf,
        .fileURL
    ]
    
    // MARK: - Properties
    
    weak var delegate: ClipboardDelegate?
    
    private var isMonitoring = false
    private var pollTimer: Timer?
    private var lastChangeCount: Int = 0
    private var isUpdatingClipboard = false  // Prevent feedback loop
    
    private let pasteboard = NSPasteboard.general
    private let pollInterval: TimeInterval = 0.5  // 500ms polling
    
    // MARK: - Initialization
    
    init() {
        lastChangeCount = pasteboard.changeCount
    }
    
    deinit {
        stopMonitoring()
    }
    
    // MARK: - Public Methods
    
    /// Start monitoring clipboard changes
    func startMonitoring() {
        guard !isMonitoring else { return }
        
        isMonitoring = true
        lastChangeCount = pasteboard.changeCount
        
        // Poll for changes (macOS doesn't have clipboard change notifications)
        pollTimer = Timer.scheduledTimer(withTimeInterval: pollInterval, repeats: true) { [weak self] _ in
            self?.checkForChanges()
        }
        
        print("ClipboardService: Started monitoring")
    }
    
    /// Stop monitoring clipboard changes
    func stopMonitoring() {
        pollTimer?.invalidate()
        pollTimer = nil
        isMonitoring = false
        
        print("ClipboardService: Stopped monitoring")
    }
    
    /// Update local clipboard with remote data
    func updateClipboard(with data: Data, type: String) {
        isUpdatingClipboard = true
        defer { isUpdatingClipboard = false }
        
        let pasteboardType = NSPasteboard.PasteboardType(type)
        
        pasteboard.clearContents()
        
        if type == NSPasteboard.PasteboardType.string.rawValue {
            // Handle string specially
            if let string = String(data: data, encoding: .utf8) {
                pasteboard.setString(string, forType: .string)
            }
        } else if type == NSPasteboard.PasteboardType.fileURL.rawValue {
            // Handle file URLs
            if let urlString = String(data: data, encoding: .utf8),
               let url = URL(string: urlString) {
                pasteboard.setString(url.absoluteString, forType: .fileURL)
            }
        } else {
            // Handle other types as raw data
            pasteboard.setData(data, forType: pasteboardType)
        }
        
        lastChangeCount = pasteboard.changeCount
        
        print("ClipboardService: Updated clipboard with \(type) (\(data.count) bytes)")
    }
    
    /// Get current clipboard content
    func getCurrentContent() -> (data: Data, type: String)? {
        // Try each supported type in order of preference
        for type in Self.supportedTypes {
            if let data = getDataForType(type) {
                return (data, type.rawValue)
            }
        }
        return nil
    }
    
    // MARK: - Private Methods
    
    private func checkForChanges() {
        guard !isUpdatingClipboard else { return }
        
        let currentCount = pasteboard.changeCount
        
        if currentCount != lastChangeCount {
            lastChangeCount = currentCount
            handleClipboardChange()
        }
    }
    
    private func handleClipboardChange() {
        // Get the clipboard content
        guard let (data, type) = getCurrentContent() else {
            return
        }
        
        // Skip if too large (e.g., > 10MB)
        guard data.count < 10_000_000 else {
            print("ClipboardService: Skipping large clipboard content (\(data.count) bytes)")
            return
        }
        
        print("ClipboardService: Clipboard changed - \(type) (\(data.count) bytes)")
        delegate?.clipboard(self, didChange: data, type: type)
    }
    
    private func getDataForType(_ type: NSPasteboard.PasteboardType) -> Data? {
        switch type {
        case .string:
            if let string = pasteboard.string(forType: .string) {
                return string.data(using: .utf8)
            }
            
        case .rtf:
            return pasteboard.data(forType: .rtf)
            
        case .html:
            return pasteboard.data(forType: .html)
            
        case .png:
            return pasteboard.data(forType: .png)
            
        case .tiff:
            return pasteboard.data(forType: .tiff)
            
        case .pdf:
            return pasteboard.data(forType: .pdf)
            
        case .fileURL:
            if let urls = pasteboard.readObjects(forClasses: [NSURL.self], options: nil) as? [URL],
               let url = urls.first {
                return url.absoluteString.data(using: .utf8)
            }
            
        default:
            return pasteboard.data(forType: type)
        }
        
        return nil
    }
}

// MARK: - Clipboard Data Types

extension ClipboardService {
    
    /// Check if a type is supported for sync
    static func isSupported(type: String) -> Bool {
        supportedTypes.contains(NSPasteboard.PasteboardType(type))
    }
    
    /// Get human-readable name for clipboard type
    static func displayName(for type: String) -> String {
        switch type {
        case NSPasteboard.PasteboardType.string.rawValue:
            return "Text"
        case NSPasteboard.PasteboardType.rtf.rawValue:
            return "Rich Text"
        case NSPasteboard.PasteboardType.html.rawValue:
            return "HTML"
        case NSPasteboard.PasteboardType.png.rawValue:
            return "PNG Image"
        case NSPasteboard.PasteboardType.tiff.rawValue:
            return "TIFF Image"
        case NSPasteboard.PasteboardType.pdf.rawValue:
            return "PDF"
        case NSPasteboard.PasteboardType.fileURL.rawValue:
            return "File"
        default:
            return "Unknown"
        }
    }
}
