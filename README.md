# Claude Accounts

A macOS menu bar app that switches the **Claude desktop app** between accounts with one click. It does not lose sessions, and you sign in to each account only one time.

## What it does

- **One-click switch.** The app saves the login of each account. A switch quits Claude, saves the current login, loads the target login, and opens Claude again. Then it checks that the login works.
- **Automatic login save.** Every 5 minutes, the app saves the login that Claude uses now. If you sign out inside Claude, the login is not lost.
- **Two-way session sync between your own accounts.** Mark your accounts as "mine" (right-click → **Mark as mine**). **Sync now** shows a preview, makes a backup, and gives every "mine" account the newest copy of every session. Accounts that are not "mine" are never read or written. Conversation transcripts are stored in one place (`~/.claude/projects`), so every account opens the same conversation. You can also turn on sync on every switch.
- **Stopped on usage limit.** Lists sessions that stopped on the 5-hour limit, with the reset time. **Open** opens the session in Claude. A notification appears one time for each stopped session, with **Switch to …** buttons for your other "mine" accounts and **Open session**. The app never switches by itself; a button click still shows the normal confirmation. If macOS does not allow notifications for the app, the menu bar icon shows a red count instead.
- **Wrong-account warning.** Shows a warning when the active account has few sessions and another account has many.
- **Backups and restore.** A daily copy of all session lists goes to `~/Backups/claude-sessions`, and the app keeps the last N days. Sync always makes a backup first. **Backups → Restore a backup…** restores any backup, and before that it saves the current state, so a restore can be undone.
- **Settings window** (⌘, in the panel), with these tabs: General, Accounts (one table with sessions, login, Mine and Show for each account), Sync, Backups (list and restore), and Advanced (Claude version, layout check, recover, files).
- **First-run guide.** Three pages: what the app does, mark your accounts and add missing logins, then sync and open-at-login. Open it again from Settings → General.
- **Upkeep.** Rename an account, hide it, or forget its saved login. You can show the account name in the menu bar, and the app can open at login.

## Install

```bash
scripts/install.sh
```

The script runs the tests, builds the app, copies it to `~/Applications`, links the CLI into `~/.local/bin`, adds a login item, and opens the app. It needs the Xcode Command Line Tools (`swiftc`) and macOS 14 or later.

## First use

1. Click the menu bar icon, then **Add account**.
2. Claude opens signed out. Sign in with your other account.
3. Do the same for each other account. After that, use **Switch**.

## CLI

```bash
claude-accounts                 # table of accounts
claude-switch status            # JSON
claude-switch switch 6bd8db16   # switch (full or 8-character account ID)
claude-switch mine 6bd8db16                         # mark as yours
claude-switch sync --dry-run                        # preview
claude-switch backups; claude-switch restore 2026-11-08
claude-switch label 6bd8db16 "me@example.com"
```

Run `claude-switch help` to see all commands.

## How it works

The Claude desktop app keeps its login in these places under `~/Library/Application Support/Claude`:

| What | Where |
|---|---|
| Web session cookie (`sessionKey`) | `Cookies` |
| OAuth token, active account | `config.json` keys `oauth:tokenCacheV2` and `lastKnownAccountUuid` |
| Web storage | `Local Storage`, `Session Storage`, `IndexedDB`, `WebStorage` |

All of these are encrypted with the key `Claude Safe Storage` in the macOS Keychain. That key is the same for every account, so a saved copy restores the login. Saved logins go to `~/Library/Application Support/Claude Account Switcher/profiles/<account>`, and only your user can read them (mode 700).

Session lists are stored per account in `claude-code-sessions/<account>/<org>/local_*.json`. Share copies those files and does not touch the transcripts.

Before every switch, the exact state goes to `.../Claude Account Switcher/last-state`, so you can restore it by hand. Every action is written to `switch.log` in the same folder.

### Crash safety

A switch writes its progress to `journal.json` before each step that changes files: `started → saved → loaded → synced`. If the engine stops in the middle (for example, the Mac loses power), `claude-switch recover` reads the journal:

| Stopped after | Recover does |
|---|---|
| `started` | nothing; no file was changed |
| `saved` (or during the load) | rolls back to `last-state` |
| `loaded`, `synced` | finishes the switch; the target login is complete |

The app runs `recover` by itself when it starts. While a journal exists, every other change is refused, and the automatic login save does not run. `tests/crash_test.sh` stops the engine after each step and checks the result (45 checks).

### Sync rules

Sync uses only the accounts marked as "mine":

1. For each session, the copy with the newest modification time goes to every "mine" account that has an older copy or no copy.
2. A session that is deleted in any "mine" account (Claude writes a `deleted_<id>` file) is not added to accounts that do not have it.
3. Sync never deletes a file.
4. Accounts that are not "mine" are not read and not written.
5. A second sync changes nothing.

`tests/sync_property_test.py` checks these rules on 500 random stores, with 3–5 accounts, some folders missing, some deleted markers, and random times. Three deliberately broken versions of the sync (ignore deleted markers, oldest wins, sync every account) each fail it. On a copy of the real data (2,897 session files, 839 changes), sync takes 0.6 s; the first backup of a day adds about 6 s.

### Version and layout guard

Before a switch, the engine checks that the Claude data folder still has the layout it knows: `config.json`, a `Cookies` database with a `cookies(host_key, name)` table, the session folder, and an account ID next to the token. If any check fails, the switch stops and changes nothing; `--force` overrides this. A Claude version that is not in the tested list, but has the known layout, may switch with a warning; after the first successful `verify`, that version counts as tested.

## Limits

- The app switches only the Claude desktop app. The `claude` CLI in a terminal has its own login.
- A switch stops tasks that run in Claude. Finish them first.
- If a saved login expires, the app tells you. Sign in again in Claude, and the app saves the new login.
- Share copies sessions into another account. Do not share into an account that another person uses.
- The app depends on how the Claude desktop app stores its files. If an update changes that, the check after each switch shows the failure.

## Development

```bash
tests/engine_test.sh                                # engine tests in a fake app folder
tests/crash_test.sh                                 # kill the engine at each switch step, then recover
tests/sync_property_test.py [cases]                 # sync rules on random stores (default 500)
swift run CoreTests                                 # app logic tests (no Xcode needed)
scripts/build.sh                                    # universal build into ./build
ARCHS=arm64 scripts/build.sh                        # faster, one architecture
build/Claude\ Accounts.app/Contents/MacOS/ClaudeAccounts --render /tmp/panel.png [dark]
build/Claude\ Accounts.app/Contents/MacOS/ClaudeAccounts --render-settings accounts /tmp/settings.png
build/Claude\ Accounts.app/Contents/MacOS/ClaudeAccounts --render-welcome 1 /tmp/welcome.png
```

The `--render` option draws the panel to a PNG file, so you can check the layout without the menu bar.

XCTest and swift-testing need Xcode. This project builds with the Command Line Tools only, so the Swift tests are a small program (`swift run CoreTests`) that exits with code 1 on failure.

## Releases

Push a tag such as `v1.0.0`. The Release workflow runs all tests, builds a universal app (arm64 and x86_64), zips it, and creates a GitHub Release with notes from the commits. If the secret `DEVELOPER_ID_P12` exists, the workflow also signs and notarizes the app.

Layout:

```
engine/claude-switch          Python engine (all file work; the app calls it)
Sources/ClaudeAccountsCore/   models, engine client, derived state (no UI)
Sources/ClaudeAccounts/       SwiftUI menu bar app
Tests/CoreTests/              Core tests, run as a program with a fake engine
tests/engine_test.sh          engine tests
scripts/                      build, install, icon
ci-pending/                   CI and release workflows (see ci-pending/README.md)
```
