import SwiftUI

struct SettingsView: View {
    @ObservedObject var controller: MouseShareController
    @State private var selectedTab: SettingsTab = .general
    
    enum SettingsTab: String, CaseIterable {
        case general = "General"
        case display = "Display"
        case security = "Security"
        case about = "About"
        
        var icon: String {
            switch self {
            case .general: return "gear"
            case .display: return "display"
            case .security: return "lock.shield"
            case .about: return "info.circle"
            }
        }
    }
    
    var body: some View {
        NavigationSplitView {
            List(SettingsTab.allCases, id: \.self, selection: $selectedTab) { tab in
                Label(tab.rawValue, systemImage: tab.icon)
            }
            .listStyle(.sidebar)
            .navigationSplitViewColumnWidth(min: 150, ideal: 180, max: 200)
        } detail: {
            Group {
                switch selectedTab {
                case .general:
                    GeneralSettingsView(controller: controller)
                case .display:
                    DisplaySettingsView(controller: controller)
                case .security:
                    SecuritySettingsView(controller: controller)
                case .about:
                    AboutView()
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(Color(nsColor: .windowBackgroundColor))
        }
        .frame(minWidth: 500, minHeight: 400)
    }
}

// MARK: - General Settings

struct GeneralSettingsView: View {
    @ObservedObject var controller: MouseShareController
    @State private var settings: AppSettings
    
    init(controller: MouseShareController) {
        self.controller = controller
        self._settings = State(initialValue: controller.settings)
    }
    
    var body: some View {
        Form {
            Section("Startup") {
                Toggle("Launch at login", isOn: $settings.launchAtLogin)
                Toggle("Auto-connect to peers", isOn: $settings.autoConnectEnabled)
            }
            
            Section("Notifications") {
                Toggle("Show connection notifications", isOn: $settings.showNotifications)
            }
            
            Section("Clipboard") {
                Toggle("Sync clipboard between computers", isOn: $settings.clipboardSyncEnabled)
                    .help("Share copied text and images between connected computers")
            }
            
            Section("Peer Identity") {
                LabeledContent("Name") {
                    Text(controller.localPeerName)
                        .foregroundStyle(.secondary)
                }
                
                LabeledContent("ID") {
                    Text(controller.localPeerId.uuidString.prefix(8) + "...")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .formStyle(.grouped)
        .padding()
        .onChange(of: settings) { _, newValue in
            controller.updateSettings(newValue)
        }
    }
}

// MARK: - Display Settings

struct DisplaySettingsView: View {
    @ObservedObject var controller: MouseShareController
    @State private var settings: AppSettings
    
    init(controller: MouseShareController) {
        self.controller = controller
        self._settings = State(initialValue: controller.settings)
    }
    
    var body: some View {
        Form {
            Section("Screen Edge Detection") {
                LabeledContent("Edge threshold") {
                    Stepper("\(settings.screenConfig.edgeThreshold) pixels", 
                            value: $settings.screenConfig.edgeThreshold, 
                            in: 1...10)
                }
                .help("Distance from screen edge to trigger transition")
                
                LabeledContent("Corner dead zone") {
                    Stepper("\(settings.screenConfig.cornerDeadZone) pixels", 
                            value: $settings.screenConfig.cornerDeadZone, 
                            in: 0...50)
                }
                .help("Area in corners that won't trigger transitions")
                
                LabeledContent("Transition delay") {
                    Picker("", selection: Binding(
                        get: { Int(settings.screenConfig.transitionDelay * 1000) },
                        set: { settings.screenConfig.transitionDelay = Double($0) / 1000 }
                    )) {
                        Text("Instant").tag(0)
                        Text("100ms").tag(100)
                        Text("250ms").tag(250)
                        Text("500ms").tag(500)
                    }
                    .labelsHidden()
                }
                .help("Time cursor must stay at edge before switching")
            }
            
            Section("Screen Links") {
                ScreenLayoutView(controller: controller, settings: $settings)
                    .frame(height: 200)
                
                if settings.screenConfig.edgeLinks.isEmpty {
                    Text("No screen edges linked. Connect to a peer and link edges from the menu bar.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(settings.screenConfig.edgeLinks) { link in
                        EdgeLinkRow(link: link, controller: controller) {
                            settings.screenConfig.edgeLinks.removeAll { $0.id == link.id }
                        }
                    }
                }
            }
        }
        .formStyle(.grouped)
        .padding()
        .onChange(of: settings) { _, newValue in
            controller.updateSettings(newValue)
        }
    }
}

struct ScreenLayoutView: View {
    @ObservedObject var controller: MouseShareController
    @Binding var settings: AppSettings
    
    var body: some View {
        GeometryReader { geometry in
            ZStack {
                // Local screen
                RoundedRectangle(cornerRadius: 8)
                    .fill(Color.blue.opacity(0.2))
                    .overlay(
                        RoundedRectangle(cornerRadius: 8)
                            .stroke(Color.blue, lineWidth: 2)
                    )
                    .frame(width: 160, height: 100)
                    .overlay {
                        VStack {
                            Image(systemName: "desktopcomputer")
                                .font(.title)
                            Text("This Mac")
                                .font(.caption)
                        }
                        .foregroundStyle(.blue)
                    }
                
                // Edge indicators
                ForEach(ScreenEdge.allCases, id: \.self) { edge in
                    EdgeIndicator(edge: edge, isLinked: settings.screenConfig.peerForEdge(edge) != nil)
                        .position(edgePosition(edge, in: geometry.size))
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }
    
    private func edgePosition(_ edge: ScreenEdge, in size: CGSize) -> CGPoint {
        let centerX = size.width / 2
        let centerY = size.height / 2
        
        switch edge {
        case .left: return CGPoint(x: centerX - 100, y: centerY)
        case .right: return CGPoint(x: centerX + 100, y: centerY)
        case .top: return CGPoint(x: centerX, y: centerY - 60)
        case .bottom: return CGPoint(x: centerX, y: centerY + 60)
        }
    }
}

struct EdgeIndicator: View {
    let edge: ScreenEdge
    let isLinked: Bool
    
    var body: some View {
        Circle()
            .fill(isLinked ? Color.green : Color.gray.opacity(0.3))
            .frame(width: 16, height: 16)
            .overlay {
                if isLinked {
                    Image(systemName: "link")
                        .font(.system(size: 8))
                        .foregroundStyle(.white)
                }
            }
    }
}

struct EdgeLinkRow: View {
    let link: ScreenEdgeLink
    @ObservedObject var controller: MouseShareController
    let onDelete: () -> Void
    
    var peerName: String {
        controller.connectedPeers.first { $0.id == link.peerId }?.displayName ?? "Unknown"
    }
    
    var body: some View {
        HStack {
            Image(systemName: "link")
                .foregroundStyle(.green)
            
            Text("\(link.edge.displayName) → \(peerName)")
            
            Spacer()
            
            Button(role: .destructive) {
                onDelete()
            } label: {
                Image(systemName: "trash")
            }
            .buttonStyle(.borderless)
        }
    }
}

// MARK: - Security Settings

struct SecuritySettingsView: View {
    @ObservedObject var controller: MouseShareController
    @State private var settings: AppSettings
    @State private var confirmPassword = ""
    @State private var showPassword = false
    
    init(controller: MouseShareController) {
        self.controller = controller
        self._settings = State(initialValue: controller.settings)
    }
    
    var body: some View {
        Form {
            Section("Encryption") {
                Toggle("Enable encryption", isOn: $settings.encryptionEnabled)
                    .help("Encrypt all network traffic with AES-256-GCM")
                
                if settings.encryptionEnabled {
                    LabeledContent("Password") {
                        HStack {
                            if showPassword {
                                TextField("", text: $settings.encryptionPassword)
                            } else {
                                SecureField("", text: $settings.encryptionPassword)
                            }
                            
                            Button {
                                showPassword.toggle()
                            } label: {
                                Image(systemName: showPassword ? "eye.slash" : "eye")
                            }
                            .buttonStyle(.borderless)
                        }
                    }
                    
                    Text("All connected computers must use the same password.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            
            Section("Permissions") {
                HStack {
                    Image(systemName: controller.hasAccessibilityPermission ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                        .foregroundStyle(controller.hasAccessibilityPermission ? .green : .orange)
                    
                    VStack(alignment: .leading) {
                        Text("Accessibility")
                            .font(.headline)
                        Text(controller.hasAccessibilityPermission ? "Granted" : "Required for keyboard and mouse capture")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    
                    Spacer()
                    
                    if !controller.hasAccessibilityPermission {
                        Button("Grant Access") {
                            _ = EventCaptureService.requestAccessibilityPermission()
                        }
                    }
                }
            }
        }
        .formStyle(.grouped)
        .padding()
        .onChange(of: settings) { _, newValue in
            controller.updateSettings(newValue)
        }
    }
}

// MARK: - About View

struct AboutView: View {
    var body: some View {
        VStack(spacing: 20) {
            Image(systemName: "rectangle.connected.to.line.below")
                .font(.system(size: 64))
                .foregroundStyle(.blue)
            
            Text("MouseShare")
                .font(.largeTitle)
                .fontWeight(.bold)
            
            Text("Version 1.0.0")
                .foregroundStyle(.secondary)
            
            Divider()
                .frame(width: 200)
            
            VStack(spacing: 8) {
                Text("Share your mouse and keyboard across multiple Macs on your local network.")
                    .multilineTextAlignment(.center)
                    .foregroundStyle(.secondary)
                
                Text("An open-source alternative to ShareMouse.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .frame(width: 300)
            
            Spacer()
            
            VStack(spacing: 4) {
                Text("Built with Swift and SwiftUI")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                
                Link("View on GitHub", destination: URL(string: "https://github.com")!)
                    .font(.caption)
            }
        }
        .padding(40)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

// MARK: - Preview

#Preview {
    SettingsView(controller: MouseShareController())
}
