import SwiftUI
import AppKit
import ClaudeAccountsCore

/// First-run guide: 1 what the app does, 2 mark your accounts and add the missing logins,
/// 3 sync and start-at-login choices.
struct WelcomeView: View {
    @EnvironmentObject var store: Store
    @State var page = 0
    var close: () -> Void = {}

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 6) {
                ForEach(0..<3) { i in
                    Capsule().fill(i <= page ? Color.accentColor : Color.secondary.opacity(0.25)).frame(height: 4)
                }
            }
            .padding([.horizontal, .top], 20)
            Group {
                switch page {
                case 0: intro
                case 1: accounts
                default: finish
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .padding(20)
            Divider()
            HStack {
                if page > 0 { Button("Back") { page -= 1 } }
                Spacer()
                Button(page < 2 ? "Continue" : "Done") {
                    if page < 2 { page += 1 } else { store.finishWelcome(); close() }
                }
                .keyboardShortcut(.defaultAction)
            }
            .padding(14)
        }
        .frame(width: 520, height: 470)
        .toggleStyle(.checkbox)  // a switch costs much more memory (see SettingsView)
        .task { await store.refresh() }
    }

    var intro: some View {
        VStack(alignment: .leading, spacing: 14) {
            Image(systemName: "person.2.circle.fill").font(.system(size: 44)).foregroundStyle(.tint)
            Text("Welcome to Claude Accounts").font(.title2.bold())
            Text("Switch the Claude desktop app between your accounts with one click. You never lose a session.")
            VStack(alignment: .leading, spacing: 10) {
                point("key.fill", "Sign in to each account one time. The app saves the login and switches with one click.")
                point("arrow.triangle.2.circlepath", "Keep the session lists of your own accounts in sync.")
                point("pause.circle", "Get a notification when a session stops on the usage limit.")
                point("externaldrive", "Daily backups, and a restore that can be undone.")
            }
            Text("The Terminal `claude` CLI is not changed. It keeps its own login.")
                .font(.caption).foregroundStyle(.secondary)
        }
    }

    func point(_ icon: String, _ text: String) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: icon).frame(width: 20).foregroundStyle(.tint)
            Text(text).fixedSize(horizontal: false, vertical: true)
        }
    }

    var accounts: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Your accounts").font(.title3.bold())
            Text("Turn on Mine for each account that is yours. Sync uses only these accounts. To add a login that is missing, click Add account and sign in one time.")
                .fixedSize(horizontal: false, vertical: true).foregroundStyle(.secondary)
            ScrollView {
                VStack(spacing: 4) {
                    ForEach(store.status?.visibleAccounts(showHidden: false) ?? []) { a in
                        HStack(spacing: 10) {
                            Avatar(account: a, size: 26)
                            VStack(alignment: .leading, spacing: 1) {
                                Text(a.title).lineLimit(1).truncationMode(.middle)
                                Text("\(a.sessions) sessions · " + (a.savedLogin ? "login saved" : "no saved login"))
                                    .font(.caption).foregroundStyle(a.savedLogin ? .green : .secondary)
                            }
                            Spacer()
                            Toggle("Mine", isOn: Binding(get: { a.owned }, set: { store.setOwned(a, $0) }))
                                .toggleStyle(.checkbox)
                        }
                        .padding(8)
                        .background(RoundedRectangle(cornerRadius: 8).fill(Color.primary.opacity(0.04)))
                    }
                }
            }
            Button { store.addAccount() } label: { Label("Add account…", systemImage: "person.badge.plus") }
        }
    }

    var finish: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Almost done").font(.title3.bold())
            Form {
                EngineToggle(title: "Sync sessions on every switch",
                             help: "Two-way sync between your mine accounts. The first sync shows a preview.",
                             key: "syncOnSwitch", value: \.syncOnSwitch)
                Toggle(isOn: Binding(get: { store.launchAtLogin },
                                     set: { LoginItem.set($0); store.launchAtLogin = LoginItem.isEnabled })) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Open at login")
                        Text("Keep the app in the menu bar.").font(.caption).foregroundStyle(.secondary)
                    }
                }
            }
            .formStyle(.grouped)
            Text("You find everything later in the menu bar icon and in Settings.")
                .font(.caption).foregroundStyle(.secondary)
        }
    }
}
