import SwiftUI
import AppKit
import ClaudeAccountsCore

@main
struct ClaudeAccountsApp: App {
    @StateObject private var store = Store()

    init() {
        let args = CommandLine.arguments
        // Debug renders: --render <png> [dark] | --render-settings <tab> <png> | --render-welcome <page> <png>
        let dark = args.contains("dark")
        if let i = args.firstIndex(of: "--render"), i + 1 < args.count {
            let path = args[i + 1]
            Task { @MainActor in
                let store = Store(startTimer: false); await store.refresh()
                await renderSnapshot(MenuView().environmentObject(store), path, dark: dark); exit(0)
            }
        }
        if let i = args.firstIndex(of: "--render-settings"), i + 2 < args.count {
            let tab = args[i + 1], path = args[i + 2]
            Task { @MainActor in
                let store = Store(startTimer: false); await store.refresh(); await store.loadBackups()
                await renderSnapshot(SettingsView(tab: tab).environmentObject(store), path, dark: dark); exit(0)
            }
        }
        if let i = args.firstIndex(of: "--render-welcome"), i + 2 < args.count {
            let page = Int(args[i + 1]) ?? 0, path = args[i + 2]
            Task { @MainActor in
                let store = Store(startTimer: false); await store.refresh()
                await renderSnapshot(WelcomeView(page: page).environmentObject(store), path, dark: dark); exit(0)
            }
        }
    }

    var body: some Scene {
        MenuBarExtra {
            MenuView().environmentObject(store)
        } label: {
            HStack(spacing: 4) {
                Image(systemName: store.menuBarBadge > 0 ? "exclamationmark.circle.fill" : "person.2.circle")
                if store.menuBarBadge > 0 { Text("\(store.menuBarBadge)") }
                else if !store.menuBarTitle.isEmpty { Text(store.menuBarTitle) }
            }
        }
        .menuBarExtraStyle(.window)
    }
}

/// Draws a view to a PNG file (debug renders) and returns.
@MainActor
func renderSnapshot<V: View>(_ view: V, _ path: String, dark: Bool) async {
    let host = NSHostingView(rootView: view.background(Color(nsColor: .windowBackgroundColor)))
    host.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
    host.frame = NSRect(origin: .zero, size: host.fittingSize)
    let win = NSWindow(contentRect: host.frame, styleMask: [.borderless], backing: .buffered, defer: false)
    win.contentView = host
    host.layoutSubtreeIfNeeded()
    try? await Task.sleep(nanoseconds: 600_000_000)
    host.layoutSubtreeIfNeeded()
    guard let rep = host.bitmapImageRepForCachingDisplay(in: host.bounds) else { return }
    host.cacheDisplay(in: host.bounds, to: rep)
    try? rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: path))
}
