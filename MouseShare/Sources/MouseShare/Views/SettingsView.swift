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
        VStack(spacing: 0) {
            // Screen arrangement area
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Text("Screen Arrangement")
                        .font(.headline)
                    Spacer()
                    Button("Detect Displays") {
                        settings.screenConfig.arrangement.initializeLocalDisplays()
                        // Also add connected peers
                        for peer in controller.connectedPeers {
                            settings.screenConfig.arrangement.updateRemoteScreen(
                                peerId: peer.id,
                                name: peer.displayName,
                                width: peer.remoteScreenWidth,
                                height: peer.remoteScreenHeight
                            )
                        }
                    }
                    .buttonStyle(.bordered)
                }
                
                Text("Drag screens to arrange them. Position remote screens adjacent to your local screens to enable mouse transitions.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                
                ScreenArrangementView(
                    arrangement: $settings.screenConfig.arrangement,
                    connectedPeers: controller.connectedPeers
                )
                .frame(height: 300)
                .background(Color(nsColor: .controlBackgroundColor))
                .cornerRadius(8)
                .overlay(
                    RoundedRectangle(cornerRadius: 8)
                        .stroke(Color.gray.opacity(0.3), lineWidth: 1)
                )
            }
            .padding()
            
            Divider()
            
            // Edge detection settings
            Form {
                Section("Edge Detection Settings") {
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
            }
            .formStyle(.grouped)
        }
        .onChange(of: settings) { _, newValue in
            controller.updateSettings(newValue)
        }
        .onAppear {
            // Initialize screens if empty
            if settings.screenConfig.arrangement.screens.isEmpty {
                settings.screenConfig.arrangement.initializeLocalDisplays()
                for peer in controller.connectedPeers {
                    settings.screenConfig.arrangement.updateRemoteScreen(
                        peerId: peer.id,
                        name: peer.displayName,
                        width: peer.remoteScreenWidth,
                        height: peer.remoteScreenHeight
                    )
                }
            }
        }
    }
}

// MARK: - Screen Arrangement View

struct ScreenArrangementView: View {
    @Binding var arrangement: ScreenArrangement
    let connectedPeers: [Peer]
    
    @State private var dragOffset: [UUID: CGSize] = [:]
    @State private var scale: CGFloat = 0.1
    @State private var viewSize: CGSize = .zero
    
    var body: some View {
        GeometryReader { geometry in
            ZStack {
                GridPattern()
                    .stroke(Color.gray.opacity(0.2), lineWidth: 0.5)
                
                screensLayer
                
                scaleIndicator
            }
            .onAppear {
                viewSize = geometry.size
                updateScale()
            }
            .onChange(of: geometry.size) { _, newSize in
                viewSize = newSize
                updateScale()
            }
        }
    }
    
    private var screensLayer: some View {
        let center = viewCenter
        let arrCenter = arrangementCenter
        
        return ForEach(arrangement.screens) { screen in
            screenItem(screen: screen, viewCenter: center, arrangeCenter: arrCenter)
        }
    }
    
    private func screenItem(screen: ArrangedScreen, viewCenter: CGPoint, arrangeCenter: CGPoint) -> some View {
        let connected = isScreenConnected(screen)
        let pos = screenPosition(screen: screen, viewCenter: viewCenter, arrangeCenter: arrangeCenter)
        
        return ScreenView(
            screen: screen,
            isLocal: screen.isLocal,
            scale: scale,
            isConnected: connected
        )
        .position(pos)
        .gesture(dragGesture(for: screen))
    }
    
    private func isScreenConnected(_ screen: ArrangedScreen) -> Bool {
        if screen.isLocal { return true }
        guard let peerId = screen.peerId else { return false }
        return connectedPeers.contains { $0.id == peerId }
    }
    
    private func screenPosition(screen: ArrangedScreen, viewCenter: CGPoint, arrangeCenter: CGPoint) -> CGPoint {
        let offsetX = dragOffset[screen.id]?.width ?? 0
        let offsetY = dragOffset[screen.id]?.height ?? 0
        let x = viewCenter.x + (CGFloat(screen.x) - arrangeCenter.x + CGFloat(screen.width) / 2) * scale + offsetX
        let y = viewCenter.y + (CGFloat(screen.y) - arrangeCenter.y + CGFloat(screen.height) / 2) * scale + offsetY
        return CGPoint(x: x, y: y)
    }
    
    private func dragGesture(for screen: ArrangedScreen) -> some Gesture {
        DragGesture()
            .onChanged { value in
                dragOffset[screen.id] = value.translation
            }
            .onEnded { value in
                let newX = screen.x + Int(value.translation.width / scale)
                let newY = screen.y + Int(value.translation.height / scale)
                arrangement.updatePosition(id: screen.id, x: newX, y: newY)
                dragOffset[screen.id] = nil
            }
    }
    
    private var scaleIndicator: some View {
        VStack {
            Spacer()
            HStack {
                Spacer()
                Text("Scale: \(Int(scale * 100))%")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .padding(4)
                    .background(Color(nsColor: .controlBackgroundColor).opacity(0.8))
                    .cornerRadius(4)
            }
        }
        .padding(8)
    }
    
    private var viewCenter: CGPoint {
        CGPoint(x: viewSize.width / 2, y: viewSize.height / 2)
    }
    
    private var arrangementCenter: CGPoint {
        guard !arrangement.screens.isEmpty else { return .zero }
        let minX = arrangement.screens.map { $0.x }.min() ?? 0
        let maxX = arrangement.screens.map { $0.x + $0.width }.max() ?? 0
        let minY = arrangement.screens.map { $0.y }.min() ?? 0
        let maxY = arrangement.screens.map { $0.y + $0.height }.max() ?? 0
        return CGPoint(x: CGFloat(minX + maxX) / 2, y: CGFloat(minY + maxY) / 2)
    }
    
    private func updateScale() {
        guard !arrangement.screens.isEmpty else { return }
        let minX = arrangement.screens.map { $0.x }.min() ?? 0
        let maxX = arrangement.screens.map { $0.x + $0.width }.max() ?? 0
        let minY = arrangement.screens.map { $0.y }.min() ?? 0
        let maxY = arrangement.screens.map { $0.y + $0.height }.max() ?? 0
        
        let totalWidth = CGFloat(maxX - minX)
        let totalHeight = CGFloat(maxY - minY)
        let padding: CGFloat = 80
        let scaleX = (viewSize.width - padding) / max(totalWidth, 1)
        let scaleY = (viewSize.height - padding) / max(totalHeight, 1)
        scale = min(scaleX, scaleY, 0.15)
    }
}

struct ScreenView: View {
    let screen: ArrangedScreen
    let isLocal: Bool
    let scale: CGFloat
    let isConnected: Bool
    
    var body: some View {
        let width = CGFloat(screen.width) * scale
        let height = CGFloat(screen.height) * scale
        
        RoundedRectangle(cornerRadius: 4)
            .fill(backgroundColor)
            .frame(width: width, height: height)
            .overlay(
                RoundedRectangle(cornerRadius: 4)
                    .stroke(borderColor, lineWidth: 2)
            )
            .overlay {
                VStack(spacing: 2) {
                    Image(systemName: isLocal ? "desktopcomputer" : "display")
                        .font(.system(size: min(width, height) * 0.2))
                    Text(screen.name)
                        .font(.system(size: max(8, min(width, height) * 0.08)))
                        .lineLimit(1)
                    Text("\(screen.width) × \(screen.height)")
                        .font(.system(size: max(6, min(width, height) * 0.06)))
                        .foregroundStyle(.secondary)
                }
                .foregroundStyle(isLocal ? .blue : (isConnected ? .green : .gray))
            }
            .shadow(color: .black.opacity(0.2), radius: 2, x: 0, y: 1)
    }
    
    private var backgroundColor: Color {
        if isLocal {
            return Color.blue.opacity(0.15)
        } else if isConnected {
            return Color.green.opacity(0.15)
        } else {
            return Color.gray.opacity(0.1)
        }
    }
    
    private var borderColor: Color {
        if isLocal {
            return .blue
        } else if isConnected {
            return .green
        } else {
            return .gray
        }
    }
}

struct GridPattern: Shape {
    func path(in rect: CGRect) -> Path {
        var path = Path()
        let spacing: CGFloat = 20
        
        // Vertical lines
        for x in stride(from: 0, through: rect.width, by: spacing) {
            path.move(to: CGPoint(x: x, y: 0))
            path.addLine(to: CGPoint(x: x, y: rect.height))
        }
        
        // Horizontal lines
        for y in stride(from: 0, through: rect.height, by: spacing) {
            path.move(to: CGPoint(x: 0, y: y))
            path.addLine(to: CGPoint(x: rect.width, y: y))
        }
        
        return path
    }
}

// Legacy views kept for compatibility
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

