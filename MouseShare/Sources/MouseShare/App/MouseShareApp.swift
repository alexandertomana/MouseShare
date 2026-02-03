import SwiftUI

@main
struct MouseShareApp: App {
    @StateObject private var controller = MouseShareController()
    @Environment(\.openWindow) private var openWindow
    
    var body: some Scene {
        // Menu bar app
        MenuBarExtra {
            MenuBarView(controller: controller)
                .task {
                    // Auto-start when the menu bar extra appears
                    try? await Task.sleep(nanoseconds: 500_000_000) // 0.5 second delay
                    if !controller.isRunning {
                        controller.start()
                    }
                }
        } label: {
            Image(systemName: menuBarIcon)
                .symbolRenderingMode(.hierarchical)
        }
        .menuBarExtraStyle(.window)
        
        // Settings window
        Window("MouseShare Settings", id: "settings") {
            SettingsView(controller: controller)
        }
        .windowStyle(.hiddenTitleBar)
        .windowResizability(.contentSize)
        .defaultSize(width: 500, height: 600)
    }
    
    private var menuBarIcon: String {
        switch controller.controlState {
        case .local:
            return controller.isRunning ? "rectangle.connected.to.line.below" : "rectangle.slash"
        case .controlling:
            return "arrow.right.circle.fill"
        case .controlled:
            return "arrow.left.circle.fill"
        }
    }
}
