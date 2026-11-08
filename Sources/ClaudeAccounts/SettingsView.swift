import SwiftUI
import AppKit
import ClaudeAccountsCore

/// The Settings window: General, Accounts, Sync, Backups, Advanced, About.
struct SettingsView: View {
    @EnvironmentObject var store: Store
    @State var tab: String = "general"

    var body: some View {
        TabView(selection: $tab) {
            GeneralTab().tabItem { Label("General", systemImage: "gearshape") }.tag("general")
            AccountsTab().tabItem { Label("Accounts", systemImage: "person.2") }.tag("accounts")
            SyncTab().tabItem { Label("Sync", systemImage: "arrow.triangle.2.circlepath") }.tag("sync")
            BackupsTab().tabItem { Label("Backups", systemImage: "externaldrive") }.tag("backups")
            AdvancedTab().tabItem { Label("Advanced", systemImage: "wrench.and.screwdriver") }.tag("advanced")
            AboutTab().tabItem { Label("About", systemImage: "info.circle") }.tag("about")
        }
        .frame(width: 620, height: 440)
        .environmentObject(store)
        .task { await store.refresh(); await store.loadBackups() }
    }
}

/// A switch bound to a boolean engine setting.
struct EngineToggle: View {
    @EnvironmentObject var store: Store
    let title: String
    let help: String
    let key: String
    let value: KeyPath<EngineSettings, Bool>

    var body: some View {
        Toggle(isOn: Binding(get: { store.status?.settings[keyPath: value] ?? false },
                             set: { store.set(key, $0) })) {
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                Text(help).font(.caption).foregroundStyle(.secondary)
            }
        }
    }
}

struct GeneralTab: View {
    @EnvironmentObject var store: Store
    var body: some View {
        Form {
            Toggle(isOn: Binding(get: { store.launchAtLogin },
                                 set: { LoginItem.set($0); store.launchAtLogin = LoginItem.isEnabled })) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Open at login")
                    Text("Keep Claude Accounts in the menu bar after a restart.").font(.caption).foregroundStyle(.secondary)
                }
            }
            EngineToggle(title: "Show account name in menu bar", help: "Show the active account next to the icon.",
                         key: "showNameInMenuBar", value: \.showNameInMenuBar)
            EngineToggle(title: "Save logins automatically", help: "Every 5 minutes, save the login Claude uses now.",
                         key: "autoSaveLogins", value: \.autoSaveLogins)
            Section("Updates") {
                HStack {
                    if let u = store.update {
                        if u.available, let tag = u.latest {
                            Text("Version \(tag) is available.")
                            Spacer()
                            Button("Update") { store.installUpdate() }
                        } else if let e = u.error {
                            Text("Cannot check: \(e)").foregroundStyle(.secondary).lineLimit(2)
                        } else {
                            Text("Version \(Store.version) is the latest.")
                        }
                    } else {
                        Text("Version \(Store.version)")
                    }
                    if store.update?.available != true {
                        Spacer()
                        Button("Check now") { Task { await store.checkForUpdate() } }
                    }
                }
            }
            Section {
                Button("Show the welcome guide again") { store.showWelcome() }
            }
        }
        .formStyle(.grouped)
    }
}

struct AccountsTab: View {
    @EnvironmentObject var store: Store
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Table(of: Account.self) {
                TableColumn("Account") { a in
                    HStack(spacing: 8) {
                        if store.isPinned(a) { Image(systemName: "pin.fill").font(.caption2).foregroundStyle(.secondary) }
                        Avatar(account: a, size: 22)
                        VStack(alignment: .leading, spacing: 0) {
                            Text(a.title).lineLimit(1).truncationMode(.middle)
                            Text(a.id.prefix(8)).font(.caption2).foregroundStyle(.secondary)
                        }
                    }
                }
                .width(min: 200, ideal: 230, max: 260)
                TableColumn("Sessions") { a in Text("\(a.sessions)").monospacedDigit() }.width(60)
                TableColumn("Login") { a in
                    Text(a.savedLogin ? (a.current ? "Active" : "Saved") : "—")
                        .foregroundStyle(a.savedLogin ? .green : .secondary)
                }.width(55)
                TableColumn("Mine") { a in
                    Toggle("", isOn: Binding(get: { a.owned }, set: { store.setOwned(a, $0) })).labelsHidden()
                }.width(40)
                TableColumn("Show") { a in
                    Toggle("", isOn: Binding(get: { !a.hidden }, set: { store.setHidden(a, !$0) }))
                        .labelsHidden().disabled(a.current)
                }.width(40)
                TableColumn("") { a in
                    Menu {
                        Button("Rename…") { store.rename(a) }
                        Button(store.isPinned(a) ? "Unpin" : "Pin to top") { store.setPinned(a, !store.isPinned(a)) }
                        if a.savedLogin { Button("Forget saved login…") { store.forget(a) } }
                        if a.needsSignInToSave { Button("Sign in to save…") { store.signInToSave(a) } }
                        Button("Copy account ID") {
                            NSPasteboard.general.clearContents(); NSPasteboard.general.setString(a.id, forType: .string)
                        }
                    } label: { Image(systemName: "ellipsis.circle") }
                    .menuStyle(.borderlessButton).fixedSize()
                }.width(30)
            } rows: {
                ForEach(store.accounts) { a in TableRow(a).draggable(a.id) }
                    .dropDestination(for: String.self) { index, ids in store.reorder(ids, to: index) }
            }
            HStack {
                Button { store.addAccount() } label: { Label("Add account…", systemImage: "person.badge.plus") }
                Spacer()
                Text("Drag to sort. Only accounts marked as mine take part in sync.").font(.caption).foregroundStyle(.secondary)
            }
        }
        .padding()
    }
}

struct SyncTab: View {
    @EnvironmentObject var store: Store
    var body: some View {
        Form {
            EngineToggle(title: "Sync sessions on every switch",
                         help: "Two-way sync between your mine accounts, while Claude is closed for the switch.",
                         key: "syncOnSwitch", value: \.syncOnSwitch)
            Section("Mine accounts") {
                let mine = store.status?.ownedAccounts ?? []
                if mine.isEmpty {
                    Text("No account is marked as mine. Mark them in the Accounts tab.").foregroundStyle(.secondary)
                } else {
                    ForEach(mine) { a in
                        LabeledContent(a.title) { Text("\(a.sessions) sessions").monospacedDigit() }
                    }
                }
            }
            Section {
                HStack {
                    Button("Sync now…") { store.syncNow() }
                    Spacer()
                    Text(store.status?.settings.syncConfirmed == true ? "Sync was confirmed before." : "The first sync shows a preview.")
                        .font(.caption).foregroundStyle(.secondary)
                }
            } footer: {
                Text("Rules: the newest copy of a session wins; a session deleted in one mine account is not added to the others; sync never deletes a file; other accounts are not touched.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }
}

struct BackupsTab: View {
    @EnvironmentObject var store: Store
    @State private var selection: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Form {
                EngineToggle(title: "Daily backup", help: "Copy all session lists to ~/Backups/claude-sessions once a day.",
                             key: "dailyBackup", value: \.dailyBackup)
                Stepper("Keep \(store.status?.settings.backupKeep ?? 7) days of backups",
                        value: Binding(get: { store.status?.settings.backupKeep ?? 7 },
                                       set: { store.setNumber("backupKeep", max(1, min(60, $0))) }), in: 1...60)
            }
            .formStyle(.grouped).frame(height: 130)
            List(store.backups, id: \.name, selection: $selection) { b in
                HStack {
                    Image(systemName: b.isUndo ? "arrow.uturn.backward.circle" : "calendar")
                    Text(b.isUndo ? "Before restore \(b.name.dropFirst("pre-restore-".count))" : b.name)
                    Spacer()
                    Text("\(b.sessions) sessions").monospacedDigit().foregroundStyle(.secondary)
                }
            }
            .frame(minHeight: 140)
            HStack {
                Button("Back up now") { Task { store.backup(); await store.loadBackups() } }
                Button("Restore selected…") {
                    if let name = selection { store.restore(name) }
                }.disabled(selection == nil)
                Spacer()
                Button("Show in Finder") {
                    NSWorkspace.shared.open(URL(fileURLWithPath: NSHomeDirectory() + "/Backups/claude-sessions"))
                }
            }
        }
        .padding()
    }
}

struct AdvancedTab: View {
    @EnvironmentObject var store: Store
    var body: some View {
        Form {
            Section("Claude") {
                LabeledContent("Version", value: store.status?.claudeVersion.isEmpty == false ? store.status!.claudeVersion : "not found")
                LabeledContent("Tested") {
                    Text(store.status?.versionTested == true ? "Yes" : "No, but switching works while the layout is known")
                        .foregroundStyle(store.status?.versionTested == true ? .green : .orange)
                }
                LabeledContent("Login layout") {
                    let probs = store.status?.layoutProblems ?? []
                    Text(probs.isEmpty ? "Known" : probs.joined(separator: "; "))
                        .foregroundStyle(probs.isEmpty ? .green : .red)
                }
            }
            Section("Repair") {
                HStack {
                    Text(store.status?.pendingRecovery == true ? "A switch stopped in the middle." : "No unfinished switch.")
                    Spacer()
                    Button("Recover now") { Task { await store.recover() } }
                        .disabled(store.status?.pendingRecovery != true)
                }
            }
            Section("Files") {
                Button("Open log") { store.openLog() }
                Button("Show saved logins folder") {
                    NSWorkspace.shared.open(URL(fileURLWithPath: NSHomeDirectory() + "/Library/Application Support/Claude Account Switcher"))
                }
                LabeledContent("Engine", value: store.engine.path.replacingOccurrences(of: NSHomeDirectory(), with: "~"))
                    .font(.caption)
            }
        }
        .formStyle(.grouped)
    }
}

struct AboutTab: View {
    @EnvironmentObject var store: Store
    @State var reportMessage = ""

    var body: some View {
        Form {
            Section("Claude Accounts") {
                LabeledContent("Version", value: Store.version)
            }
            Section("Report a problem") {
                Text("The debug report has the app and Claude versions, the layout check, the settings and the last 200 log lines. Emails and account IDs show as \"account 1\", \"account 2\" and so on.")
                    .font(.caption).foregroundStyle(.secondary)
                HStack {
                    Button("Copy debug report") { Task { reportMessage = await store.copyDebugReport() } }
                    Text(reportMessage).font(.caption).foregroundStyle(.secondary)
                }
            }
            UninstallSection()
        }
        .formStyle(.grouped)
    }
}

struct UninstallSection: View {
    @EnvironmentObject var store: Store
    var body: some View {
        Section("Uninstall") {
            HStack {
                Text("Remove the app, the login item and the CLI commands. Saved logins and backups stay.")
                    .font(.callout).foregroundStyle(.secondary)
                Spacer()
                Button("Uninstall…") { store.uninstall() }  // the engine refuses while a switch runs
            }
        }
    }
}
