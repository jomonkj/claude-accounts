import SwiftUI
import AppKit
import ClaudeAccountsCore

extension Account {
    var color: Color {
        let palette: [Color] = [.blue, .purple, .pink, .orange, .teal, .indigo, .green, .mint]
        return palette[colorIndex % palette.count]
    }
}

struct Avatar: View {
    let account: Account
    var size: CGFloat = 32
    var body: some View {
        ZStack {
            Circle().fill(account.color.gradient)
            Text(account.initials).font(.system(size: size * 0.38, weight: .semibold)).foregroundStyle(.white)
        }
        .frame(width: size, height: size)
        .opacity(account.hidden ? 0.5 : 1)
    }
}

struct SectionTitle: View {
    let text: String
    var body: some View {
        Text(text.uppercased())
            .font(.system(size: 10, weight: .semibold)).foregroundStyle(.secondary)
            .padding(.horizontal, 16).padding(.top, 10).padding(.bottom, 2)
    }
}

struct HoverRow<Content: View>: View {
    var highlight = true
    /// A light accent tint that marks the row (the active account).
    var selected = false
    @ViewBuilder let content: Content
    @State private var hover = false
    var body: some View {
        content
            .padding(.horizontal, 10).padding(.vertical, 8)
            .background(RoundedRectangle(cornerRadius: 8).fill(
                selected ? Color.accentColor.opacity(0.09) : hover && highlight ? Color.primary.opacity(0.06) : .clear))
            .contentShape(Rectangle())
            .onHover { hover = $0 }
    }
}

struct AccountRow: View {
    @EnvironmentObject var store: Store
    let account: Account

    var body: some View {
        HoverRow(highlight: !account.current, selected: account.current) {
            HStack(spacing: 10) {
                Avatar(account: account)
                VStack(alignment: .leading, spacing: 3) {
                    titleLine
                    if let line = account.detailsLine {
                        Text(line).font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(1).truncationMode(.tail)
                    }
                    if let state = store.status?.liveState(for: account.id, usage: store.liveUsage) {
                        LiveUsageView(state: state).padding(.vertical, 1)
                    }
                    Text(account.lastUsedLine)
                        .font(.system(size: 10.5)).foregroundStyle(.tertiary).lineLimit(1)
                        .help("\(account.sessions) sessions")
                    if !account.savedLogin && !account.current {
                        Text(account.loginText).font(.system(size: 10.5)).foregroundStyle(.orange).lineLimit(1)
                    }
                    // Re-check every 30 s, so the line goes away when the reset time passes.
                    TimelineView(.periodic(from: .now, by: 30)) { ctx in
                        if let line = store.status?.resetLine(for: account.id, now: ctx.date) {
                            Label(line, systemImage: "clock").font(.system(size: 10.5)).foregroundStyle(.orange).lineLimit(1)
                        }
                    }
                }
                Spacer(minLength: 6)
                trailing
            }
        }
        .contextMenu { AccountMenu(account: account) }
    }

    /// Name, then small marks: pinned, mine, and a key when the login is saved (time in the help text).
    var titleLine: some View {
        HStack(spacing: 5) {
            Text(account.title).font(.system(size: 13, weight: .semibold)).lineLimit(1).truncationMode(.middle)
            if store.isPinned(account) {
                Image(systemName: "pin.fill").font(.system(size: 9)).foregroundStyle(.secondary)
                    .help("Pinned to the top")
            }
            if account.owned {
                Text("MINE").font(.system(size: 8.5, weight: .bold))
                    .padding(.horizontal, 4).padding(.vertical, 1)
                    .background(Capsule().fill(Color.accentColor.opacity(0.18)))
                    .foregroundStyle(Color.accentColor)
                    .help("Marked as mine: sync includes this account")
            }
            if account.savedLogin {
                Image(systemName: "key.fill").font(.system(size: 9)).foregroundStyle(.green)
                    .help(account.loginText)
            }
        }
    }

    @ViewBuilder var trailing: some View {
        if account.current {
            Label("Active", systemImage: "checkmark.circle.fill")
                .font(.system(size: 11, weight: .semibold)).foregroundStyle(.green)
        } else if account.savedLogin {
            Button("Switch") { store.switchTo(account) }
                .buttonStyle(.borderedProminent).controlSize(.small).disabled(store.busy != nil)
        } else if account.needsSignInToSave {
            Button("Sign in to save") { store.signInToSave(account) }
                .controlSize(.small).disabled(store.busy != nil)
                .help("Sign in to this account in Claude one time. The app saves the login. After that, one click switches to it.")
        }
    }
}

/// The live usage on/off switch at the top of the account list. The same setting as in
/// Settings → Accounts. A button, not a slider switch: the first slider switch costs about 50 MB (#22).
struct LiveUsageToggle: View {
    @EnvironmentObject var store: Store

    var body: some View {
        let on = store.status?.settings.liveUsageOn ?? false
        Button {
            store.set("liveUsage", !on)
        } label: {
            Label("Usage", systemImage: on ? "chart.bar.fill" : "chart.bar")
                .font(.system(size: 10, weight: .semibold))
                .padding(.horizontal, 7).padding(.vertical, 2)
                .background(Capsule().fill(on ? Color.accentColor.opacity(0.18) : Color.primary.opacity(0.07)))
                .foregroundStyle(on ? Color.accentColor : Color.secondary)
        }
        .buttonStyle(.plain)
        .disabled(store.busy != nil)
        .help(on ? "Live usage from claude.ai is on. Click to turn it off."
                 : "Show the 5-hour and weekly usage of each account, live from claude.ai. The app sends one request to claude.ai for each account, with that account's own saved login. macOS asks one time for the \"Claude Safe Storage\" key.")
    }
}

/// Live usage under an account: one bar each for the 5-hour and the weekly limit, or why it is unavailable.
struct LiveUsageView: View {
    let state: LiveRowState

    var body: some View {
        switch state {
        case .bars(let bars):
            VStack(alignment: .leading, spacing: 3) {
                ForEach(bars, id: \.label) { UsageBarView(bar: $0) }
            }
            .help(bars.map { "\($0.label == "5h" ? "5-hour limit" : "Weekly limit"): \($0.text) used" }.joined(separator: "\n")
                  + "\nLive from claude.ai")
        case .unavailable(let reason):
            Label("Usage unavailable", systemImage: "exclamationmark.circle")
                .font(.system(size: 10.5)).foregroundStyle(.secondary).lineLimit(1)
                .help(reason)
        }
    }
}

struct UsageBarView: View {
    let bar: UsageBar

    var color: Color {
        switch bar.level {
        case .normal: .accentColor
        case .high: .orange
        case .critical: .red
        }
    }

    var body: some View {
        HStack(spacing: 5) {
            Text(bar.label).font(.system(size: 10, weight: .medium)).foregroundStyle(.secondary)
                .frame(width: 32, alignment: .leading)
            GeometryReader { g in
                ZStack(alignment: .leading) {
                    Capsule().fill(Color.primary.opacity(0.12))
                    Capsule().fill(color).frame(width: max(g.size.width * bar.fraction, bar.fraction > 0 ? 4 : 0))
                }
            }
            .frame(height: 5)
            // Only a high or critical percent draws the eye; a normal one stays quiet.
            Text(bar.text).font(.system(size: 10.5, weight: bar.level == .normal ? .medium : .semibold)).monospacedDigit()
                .foregroundStyle(bar.level == .normal ? AnyShapeStyle(.secondary) : AnyShapeStyle(color))
                .frame(width: 32, alignment: .trailing)
        }
        .frame(maxWidth: .infinity)
    }
}

/// The actions of one account. The panel (right-click) and Settings → Accounts (⋯ button) use the same menu.
/// Actions that do not fit the current account stay in the menu, disabled, with a help text.
struct AccountMenu: View {
    @EnvironmentObject var store: Store
    let account: Account

    var body: some View {
        Button("Rename…") { store.rename(account) }
        Button(account.owned ? "Not mine" : "Mark as mine") { store.setOwned(account, !account.owned) }
        Button(store.isPinned(account) ? "Unpin" : "Pin to top") { store.setPinned(account, !store.isPinned(account)) }
        if account.savedLogin { Button("Forget saved login…") { store.forget(account) } }
        if account.needsSignInToSave { Button("Sign in to save…") { store.signInToSave(account) } }
        Button(account.hidden ? "Show in list" : "Hide from list") { store.setHidden(account, !account.hidden) }
            .disabled(account.current).help(account.current ? "The current account always shows." : "")
        Button("Remove account…") { store.remove(account) }
            .disabled(account.current)
            .help(account.current ? "You cannot remove the current account. Switch to another account first." : "")
        Divider()
        Button("Copy account ID") {
            NSPasteboard.general.clearContents(); NSPasteboard.general.setString(account.id, forType: .string)
        }
    }
}

struct PausedRow: View {
    @EnvironmentObject var store: Store
    let session: PausedSession

    var body: some View {
        HoverRow {
            HStack(spacing: 10) {
                Image(systemName: "pause.circle.fill").font(.system(size: 22)).foregroundStyle(.orange)
                VStack(alignment: .leading, spacing: 2) {
                    Text(session.title).font(.system(size: 12, weight: .medium)).lineLimit(1).truncationMode(.tail)
                    TimelineView(.periodic(from: .now, by: 30)) { ctx in
                        Text(subtitle(ctx.date)).font(.system(size: 10.5)).foregroundStyle(.secondary).lineLimit(1)
                    }
                }
                Spacer(minLength: 6)
                Button("Open") { store.open(session) }.controlSize(.small)
                    .help("Open this session in Claude, then type: continue")
            }
        }
    }

    func subtitle(_ now: Date) -> String {
        store.status?.pausedSubtitle(session, now: now) ?? "Limit reached"
    }
}

struct BannerView: View {
    let banner: Banner
    let close: () -> Void
    var body: some View {
        let (icon, tint, text): (String, Color, String) = {
            switch banner {
            case .error(let t): return ("exclamationmark.triangle.fill", .red, t)
            case .warning(let t): return ("exclamationmark.circle.fill", .orange, t)
            case .success(let t): return ("checkmark.circle.fill", .green, t)
            case .info(let t): return ("info.circle.fill", .blue, t)
            }
        }()
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: icon).foregroundStyle(tint)
            Text(text).font(.system(size: 11)).fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 4)
            Button(action: close) { Image(systemName: "xmark").font(.system(size: 9, weight: .bold)) }
                .buttonStyle(.borderless).foregroundStyle(.secondary)
        }
        .padding(10)
        .background(RoundedRectangle(cornerRadius: 8).fill(tint.opacity(0.12)))
        .padding(.horizontal, 10).padding(.top, 8)
    }
}

struct MenuView: View {
    @EnvironmentObject var store: Store

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Divider()
            if let b = store.banner { BannerView(banner: b) { store.banner = nil } }
            if let u = store.update, u.available, let tag = u.latest {
                HStack(spacing: 8) {
                    Image(systemName: "arrow.down.circle.fill").foregroundStyle(.blue)
                    Text("Version \(tag) is available.").font(.system(size: 11))
                    Spacer()
                    Button("Update") { store.installUpdate() }.controlSize(.small).disabled(store.busy != nil)
                }
                .padding(10)
                .background(RoundedRectangle(cornerRadius: 8).fill(Color.blue.opacity(0.1)))
                .padding(.horizontal, 10).padding(.top, 8)
            }
            if let g = store.status?.guardBanner, store.banner == nil { BannerView(banner: g) {} }
            if let w = store.wrongAccountHint, store.banner == nil { BannerView(banner: .warning(w)) {} }
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    HStack(alignment: .lastTextBaseline) {
                        SectionTitle(text: "Accounts")
                        Spacer()
                        LiveUsageToggle().padding(.trailing, 14)
                    }
                    VStack(spacing: 1) {
                        ForEach(store.visibleAccounts) { AccountRow(account: $0) }
                    }.padding(.horizontal, 6)
                    if store.hiddenCount > 0 {
                        Button(store.showHidden ? "Hide \(store.hiddenCount) hidden accounts" : "Show \(store.hiddenCount) hidden accounts") {
                            store.showHidden.toggle()
                        }
                        .buttonStyle(.borderless).font(.system(size: 11)).padding(.horizontal, 16).padding(.vertical, 4)
                    }
                    if let paused = store.status?.paused, !paused.isEmpty {
                        SectionTitle(text: "Stopped on usage limit")
                        VStack(spacing: 1) { ForEach(paused) { PausedRow(session: $0) } }.padding(.horizontal, 6)
                        if store.status?.canSwitchElsewhere == true {
                            Text("Switch to another account to continue now, then open the session and type \"continue\".")
                                .font(.system(size: 10)).foregroundStyle(.secondary).padding(.horizontal, 16).padding(.top, 2)
                        }
                    }
                }
                .padding(.bottom, 6)
            }
            // Room for 4 accounts with usage bars and the stopped sessions; scrolls on a small screen.
            .frame(maxHeight: min(600, (NSScreen.main?.visibleFrame.height ?? 800) * 0.7))
            .fixedSize(horizontal: false, vertical: true)
            Divider()
            actions
            Divider()
            footer
        }
        .frame(width: 380)
        .task { await store.refresh(); await store.refreshLiveUsage() }
        .background(WindowReader { store.panelWindow = $0 })
        .onReceive(NotificationCenter.default.publisher(for: NSWindow.didBecomeKeyNotification)) { _ in
            Task { await store.refresh() }
        }
    }

    var header: some View {
        HStack(spacing: 10) {
            if let c = store.current { Avatar(account: c, size: 30) }
            else { Image(systemName: "person.crop.circle.badge.questionmark").font(.system(size: 24)).foregroundStyle(.secondary) }
            VStack(alignment: .leading, spacing: 1) {
                Text(store.current?.title ?? "Not signed in").font(.system(size: 13, weight: .semibold)).lineLimit(1)
                Text(store.busy ?? headerSubtitle).font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(1)
            }
            Spacer()
            if store.busy != nil { ProgressView().controlSize(.small) }
            else {
                Button { Task { await store.refresh() } } label: { Image(systemName: "arrow.clockwise") }
                    .buttonStyle(.borderless).help("Refresh")
            }
        }
        .padding(12)
    }

    var headerSubtitle: String {
        guard let s = store.status else { return "Loading…" }
        if !s.claudeRunning { return "Claude is not running" }
        return s.signedIn ? "Signed in to Claude" : "Claude is signed out"
    }

    var actions: some View {
        HStack(spacing: 8) {
            Button { store.addAccount() } label: { Label("Add account", systemImage: "person.badge.plus") }
            Button { store.syncNow() } label: { Label("Sync now", systemImage: "arrow.triangle.2.circlepath") }
            Menu {
                Button("Back up now") { store.backup() }
                Button("Restore a backup…") { store.restoreBackup() }
            } label: { Label("Backups", systemImage: "externaldrive") }
            .menuStyle(.borderlessButton).fixedSize()
        }
        .controlSize(.small).disabled(store.busy != nil)
        .padding(.horizontal, 12).padding(.vertical, 10)
    }

    var footer: some View {
        HStack(spacing: 12) {
            Text("v\(Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "dev")")
                .font(.system(size: 10)).foregroundStyle(.tertiary)
            Spacer()
            Button("Settings…") { store.showSettings() }.keyboardShortcut(",")
            Button("Open Claude") { NSWorkspace.shared.open(URL(fileURLWithPath: "/Applications/Claude.app")) }
            Button("Quit") { NSApp.terminate(nil) }.keyboardShortcut("q")
        }
        .buttonStyle(.borderless).font(.system(size: 11))
        .padding(.horizontal, 12).padding(.vertical, 9)
    }
}


/// Gives the NSWindow that holds a view, once it is in a window.
struct WindowReader: NSViewRepresentable {
    let found: (NSWindow?) -> Void
    func makeNSView(context: Context) -> NSView {
        let v = NSView()
        DispatchQueue.main.async { [weak v] in found(v?.window) }
        return v
    }
    func updateNSView(_ v: NSView, context: Context) {
        DispatchQueue.main.async { [weak v] in if let w = v?.window { found(w) } }
    }
}
