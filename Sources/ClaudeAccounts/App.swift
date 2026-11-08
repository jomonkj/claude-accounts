import SwiftUI
import AppKit
import ClaudeAccountsCore

@main
struct ClaudeAccountsApp: App {
    @StateObject private var store = Store()

    init() {
        let args = CommandLine.arguments
        if let i = args.firstIndex(of: "--render"), i + 1 < args.count {
            let path = args[i + 1], dark = args.contains("dark")
            Task { @MainActor in await renderSnapshot(path, dark: dark); exit(0) }
        }
    }

    var body: some Scene {
        MenuBarExtra {
            MenuView().environmentObject(store)
        } label: {
            HStack(spacing: 4) {
                Image(systemName: "person.2.circle")
                if !store.menuBarTitle.isEmpty { Text(store.menuBarTitle) }
            }
        }
        .menuBarExtraStyle(.window)
    }
}

/// Debug: `ClaudeAccounts --render out.png [dark]` draws the panel to a PNG and exits.
@MainActor
func renderSnapshot(_ path: String, dark: Bool) async {
    let store = Store(startTimer: false)
    await store.refresh()
    let host = NSHostingView(rootView: MenuView().environmentObject(store)
        .background(Color(nsColor: .windowBackgroundColor)))
    host.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
    host.frame = NSRect(origin: .zero, size: host.fittingSize)
    let win = NSWindow(contentRect: host.frame, styleMask: [.borderless], backing: .buffered, defer: false)
    win.contentView = host
    host.layoutSubtreeIfNeeded()
    try? await Task.sleep(nanoseconds: 400_000_000)
    host.layoutSubtreeIfNeeded()
    guard let rep = host.bitmapImageRepForCachingDisplay(in: host.bounds) else { return }
    host.cacheDisplay(in: host.bounds, to: rep)
    try? rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: path))
}
