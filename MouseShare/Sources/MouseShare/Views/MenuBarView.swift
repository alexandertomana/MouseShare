import SwiftUI

struct MenuBarView: View {
    @ObservedObject var controller: MouseShareController
    @Environment(\.openWindow) private var openWindow
    
    var body: some View {
        VStack(spacing: 0) {
            // Header
            headerSection
            
            Divider()
            
            // Status
            statusSection
            
            Divider()
            
            // Connected Peers
            if !controller.connectedPeers.isEmpty {
                connectedPeersSection
                Divider()
            }
            
            // Discovered Peers
            if !controller.discoveredPeers.isEmpty {
                discoveredPeersSection
                Divider()
            }
            
            // Actions
            actionsSection
        }
        .frame(width: 280)
        .background(Color(nsColor: .windowBackgroundColor))
    }
    
    // MARK: - Sections
    
    private var headerSection: some View {
        HStack {
            Image(systemName: "rectangle.connected.to.line.below")
                .font(.title2)
                .foregroundStyle(.blue)
            
            VStack(alignment: .leading, spacing: 2) {
                Text("MouseShare")
                    .font(.headline)
                Text(controller.localPeerName)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            
            Spacer()
            
            Toggle("", isOn: Binding(
                get: { controller.isRunning },
                set: { newValue in
                    if newValue { controller.start() }
                    else { controller.stop() }
                }
            ))
            .toggleStyle(.switch)
            .labelsHidden()
        }
        .padding()
    }
    
    private var statusSection: some View {
        HStack {
            statusIndicator
            
            VStack(alignment: .leading, spacing: 2) {
                Text(statusTitle)
                    .font(.subheadline)
                    .fontWeight(.medium)
                Text(controller.statusMessage)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            
            Spacer()
        }
        .padding(.horizontal)
        .padding(.vertical, 10)
    }
    
    private var statusIndicator: some View {
        Circle()
            .fill(statusColor)
            .frame(width: 10, height: 10)
            .shadow(color: statusColor.opacity(0.5), radius: 3)
    }
    
    private var statusTitle: String {
        if !controller.isRunning {
            return "Stopped"
        }
        switch controller.controlState {
        case .local:
            return "Ready"
        case .controlling:
            return "Controlling"
        case .controlled:
            return "Being Controlled"
        }
    }
    
    private var statusColor: Color {
        if !controller.isRunning {
            return .gray
        }
        switch controller.controlState {
        case .local:
            return .green
        case .controlling:
            return .blue
        case .controlled:
            return .orange
        }
    }
    
    private var connectedPeersSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Connected")
                .font(.caption)
                .foregroundStyle(.secondary)
                .padding(.horizontal)
                .padding(.top, 8)
            
            ForEach(controller.connectedPeers) { peer in
                ConnectedPeerRow(peer: peer, controller: controller)
            }
            .padding(.horizontal)
            .padding(.bottom, 8)
        }
    }
    
    private var discoveredPeersSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Discovered")
                .font(.caption)
                .foregroundStyle(.secondary)
                .padding(.horizontal)
                .padding(.top, 8)
            
            ForEach(controller.discoveredPeers.filter { peer in
                !controller.connectedPeers.contains { $0.id == peer.id }
            }) { peer in
                DiscoveredPeerRow(peer: peer, controller: controller)
            }
            .padding(.horizontal)
            .padding(.bottom, 8)
        }
    }
    
    private var actionsSection: some View {
        VStack(spacing: 4) {
            Button {
                openWindow(id: "settings")
            } label: {
                HStack {
                    Image(systemName: "gear")
                    Text("Settings...")
                    Spacer()
                    Text("⌘,")
                        .foregroundStyle(.secondary)
                }
            }
            .buttonStyle(.plain)
            .padding(.horizontal)
            .padding(.vertical, 8)
            
            Divider()
            
            Button {
                if !controller.hasAccessibilityPermission {
                    _ = EventCaptureService.requestAccessibilityPermission()
                }
            } label: {
                HStack {
                    Image(systemName: controller.hasAccessibilityPermission ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                        .foregroundStyle(controller.hasAccessibilityPermission ? .green : .orange)
                    Text("Accessibility Permission")
                    Spacer()
                    if !controller.hasAccessibilityPermission {
                        Text("Required")
                            .font(.caption)
                            .foregroundStyle(.orange)
                    }
                }
            }
            .buttonStyle(.plain)
            .padding(.horizontal)
            .padding(.vertical, 8)
            
            Divider()
            
            Button {
                NSApplication.shared.terminate(nil)
            } label: {
                HStack {
                    Image(systemName: "power")
                    Text("Quit MouseShare")
                    Spacer()
                    Text("⌘Q")
                        .foregroundStyle(.secondary)
                }
            }
            .buttonStyle(.plain)
            .padding(.horizontal)
            .padding(.vertical, 8)
        }
    }
}

// MARK: - Peer Rows

struct ConnectedPeerRow: View {
    @ObservedObject var peer: Peer
    var controller: MouseShareController
    
    var body: some View {
        HStack {
            Circle()
                .fill(peer.isOnline ? .green : .gray)
                .frame(width: 8, height: 8)
            
            VStack(alignment: .leading, spacing: 2) {
                Text(peer.displayName)
                    .font(.subheadline)
                Text(peer.statusDescription)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            
            Spacer()
            
            Menu {
                ForEach(ScreenEdge.allCases, id: \.self) { edge in
                    Button("Link to \(edge.displayName) edge") {
                        controller.linkEdge(edge, to: peer)
                    }
                }
                
                Divider()
                
                Button("Disconnect") {
                    controller.disconnect(from: peer)
                }
            } label: {
                Image(systemName: "ellipsis.circle")
                    .foregroundStyle(.secondary)
            }
            .menuStyle(.borderlessButton)
            .frame(width: 24)
        }
        .padding(.vertical, 4)
    }
}

struct DiscoveredPeerRow: View {
    @ObservedObject var peer: Peer
    var controller: MouseShareController
    
    var body: some View {
        HStack {
            Circle()
                .fill(.gray.opacity(0.5))
                .frame(width: 8, height: 8)
            
            VStack(alignment: .leading, spacing: 2) {
                Text(peer.displayName)
                    .font(.subheadline)
                Text("Discovered")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            
            Spacer()
            
            Button("Connect") {
                controller.connect(to: peer)
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
        }
        .padding(.vertical, 4)
    }
}

// MARK: - Preview

#Preview {
    MenuBarView(controller: MouseShareController())
}
