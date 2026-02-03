# MouseShare

A lightweight, native macOS application for sharing mouse and keyboard input across multiple computers on a local network. This is an open-source alternative to ShareMouse.

## Features

- **Seamless Mouse Sharing**: Move your mouse cursor to the screen edge to control another computer
- **Keyboard Sharing**: Type on any connected computer using a single keyboard
- **Clipboard Sync**: Copy on one computer, paste on another
- **Secure Communication**: AES-GCM encryption for all network traffic
- **Auto Discovery**: Automatically finds other MouseShare instances via Bonjour
- **Lightweight**: Native Swift implementation with minimal resource usage
- **Menu Bar App**: Unobtrusive menu bar interface

## Requirements

- macOS 13.0 (Ventura) or later
- Local network connection (Wi-Fi or Ethernet)
- Accessibility permissions (for capturing input events)
- Local Network permissions (for peer discovery)

## Architecture

```
┌─────────────────────────────────────────────────────────────────────┐
│                         MouseShare App                               │
├─────────────────────────────────────────────────────────────────────┤
│  ┌─────────────┐  ┌─────────────┐  ┌─────────────┐  ┌─────────────┐ │
│  │   SwiftUI   │  │   Menu Bar  │  │  Settings   │  │   Display   │ │
│  │    App      │  │    View     │  │    View     │  │   Config    │ │
│  └──────┬──────┘  └──────┬──────┘  └──────┬──────┘  └──────┬──────┘ │
│         └─────────────────┴────────────────┴─────────────────┘       │
│                                    │                                 │
│  ┌─────────────────────────────────┴──────────────────────────────┐ │
│  │                    MouseShareController                         │ │
│  │  (Coordinates all services, manages state machine)              │ │
│  └─────────────────────────────────┬──────────────────────────────┘ │
│                                    │                                 │
│  ┌─────────────────────────────────┴──────────────────────────────┐ │
│  │                         Services Layer                          │ │
│  │  ┌───────────────┐ ┌───────────────┐ ┌───────────────┐          │ │
│  │  │ EventCapture  │ │ EventInject   │ │ ScreenEdge    │          │ │
│  │  │ Service       │ │ Service       │ │ Service       │          │ │
│  │  │ (CGEventTap)  │ │ (CGEvent)     │ │ (Boundaries)  │          │ │
│  │  └───────────────┘ └───────────────┘ └───────────────┘          │ │
│  │  ┌───────────────┐ ┌───────────────┐ ┌───────────────┐          │ │
│  │  │ Network       │ │ InputServer/  │ │ Clipboard     │          │ │
│  │  │ Discovery     │ │ Client        │ │ Service       │          │ │
│  │  │ (Bonjour)     │ │ (TCP)         │ │ (Pasteboard)  │          │ │
│  │  └───────────────┘ └───────────────┘ └───────────────┘          │ │
│  │  ┌───────────────┐                                              │ │
│  │  │ Encryption    │                                              │ │
│  │  │ Service       │                                              │ │
│  │  │ (AES-GCM)     │                                              │ │
│  │  └───────────────┘                                              │ │
│  └─────────────────────────────────────────────────────────────────┘ │
└─────────────────────────────────────────────────────────────────────┘
```

## How It Works

1. **Discovery**: MouseShare advertises itself via Bonjour and discovers other instances on the local network
2. **Connection**: When a peer is found, a secure TCP connection is established
3. **Screen Edge Detection**: When the mouse cursor reaches a configured screen edge, control transfers to the adjacent peer
4. **Event Capture**: Mouse and keyboard events are captured using CGEventTap
5. **Transmission**: Events are serialized, encrypted, and sent over TCP to the controlling peer
6. **Injection**: The receiving peer deserializes events and injects them using CGEvent
7. **Clipboard Sync**: Clipboard changes are detected and synchronized between connected peers

## Building

```bash
cd MouseShare
swift build -c release
```

## Running

```bash
swift run MouseShare
```

Or build and run the `.app` bundle from Xcode.

## Permissions

MouseShare requires the following permissions:

1. **Accessibility**: Required to capture global keyboard and mouse events
   - Go to System Settings > Privacy & Security > Accessibility
   - Add MouseShare to the allowed apps

2. **Local Network**: Required for Bonjour discovery
   - A prompt will appear on first launch

## Configuration

- **Screen Layout**: Configure which edge of your screen connects to which peer
- **Encryption**: Enable/disable encryption with a shared password
- **Clipboard Sync**: Enable/disable clipboard synchronization
- **Hotkey**: Configure a hotkey to manually switch control

## Network Protocol

- **Discovery**: Bonjour/mDNS with service type `_mouseshare._tcp`
- **Communication**: TCP on port 24801
- **Encryption**: AES-256-GCM when enabled

## License

MIT License
