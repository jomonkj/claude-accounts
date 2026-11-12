# Live usage from claude.ai (spike #39)

Question: can the engine get the usage numbers of each **saved** login, without changing the active Claude login?

**Answer: yes. One request gives every bar on the Usage page: session, weekly, and Fable.** Go, as an opt-in, with the conditions at the end.

Tested on 2026-11-12 with `scripts/spikes/usage-live.py` on two saved logins that were not active. No token, cookie, email or ID is in this file.

## 1. The request and the response

- One `GET https://claude.ai/api/organizations/<org>/usage`.
- `<org>` is the value of the `lastActiveOrg` cookie in the saved profile.
- The response is JSON. The fields this app needs:

  | Field | Shape | Meaning |
  |---|---|---|
  | `five_hour` | `{utilization, resets_at}` | Current session (5-hour window). `utilization` is a percent (0–100). `resets_at` is null when no session has started. |
  | `seven_day` | `{utilization, resets_at}` | Weekly limit, all models. `resets_at` is an ISO time in UTC. |
  | `extra_usage` | `{utilization, resets_at}` | Extra usage. Null values on the tested accounts. |
  | `limits` | list of `{kind, percent, resets_at, scope, is_active, group, severity}` | One entry per bar on the Usage page. Seen kinds: `session`, `weekly_all`, `weekly_scoped`. A `weekly_scoped` entry has `scope.model.display_name`: this is the Fable bar. |
  | `weekly_scoped_shares` | list of `{limit_index, used_percent_of_weekly, allowance_percent_of_weekly}` | For a scoped limit: its share of the weekly limit. `allowance_percent_of_weekly=50` matches "Up to 50% of your weekly limit". |
  | `spend` | `{used, limit, percent, enabled, …}` | Extra usage spending. Not enabled on the tested account. |

- **Use `limits`, not the older top-level fields.** `limits` has the Fable bar, and its `kind` names are clear. The top-level `five_hour` and `seven_day` give the same numbers as the `session` and `weekly_all` entries.
- Many other top-level fields have internal code names and were null: `seven_day_opus`, `seven_day_sonnet`, `seven_day_cowork`, `seven_day_oauth_apps`, `pace`, `indicator`, `seven_day_breakdown`, and others.

### Results against the Usage page

| Account | Field | Usage page | Response |
|---|---|---|---|
| account 1 | weekly | — | 17%, resets Tue 2026-11-17 14:00 UTC |
| account 2 | weekly | 16%, resets Mon 8:30 PM IST | 16%, resets 2026-11-16 15:00 UTC (= Mon 8:30 PM IST) |
| account 2 | session | 3%, resets 2:40 AM (read before 2:40 AM) | 0%, `resets_at` null (read after 2:40 AM: the window ended) |
| account 2 | Fable | 29%, "Up to 50% of your weekly limit" | `limits[kind=weekly_scoped].percent` = 29, resets Mon 15:00 UTC; `allowance_percent_of_weekly` = 50 |

The weekly and Fable values and the reset time of account 2 match the page exactly. Running the script a second time gave the same values.

## 2. What the request needs

- **Credential:** the saved profile's `sessionKey` cookie. The request also sends `lastActiveOrg`, `cf_clearance`, `__cf_bm`, `anthropic-device-id`, `routingHint`, `__Host-ant_trusted_device` and `sessionKeyV3`, as the desktop app would. Which of these are really needed was not tested.
- **Decryption:** the cookies in a saved profile are Chromium "v10" values: AES-128-CBC, IV of 16 spaces. The key is PBKDF2-HMAC-SHA1 of the "Claude Safe Storage" Keychain password, salt `saltysalt`, 1003 rounds, 16 bytes. Cookie database version 24 adds a 32-byte SHA-256 of the host in front of each value.
- **Keychain:** reading "Claude Safe Storage" shows a macOS dialog. The spike used `/usr/bin/security` and "Allow" (once).
- **Org ID:** from the `lastActiveOrg` cookie. No other lookup is needed.
- **Cloudflare:** a plain HTTP request with a browser User-Agent and the saved `cf_clearance` cookie got HTTP 200.

## 3. Effect on the saved login

- The script reads a **copy** of the saved Cookies database. The saved profile files do not change.
- A second request with the same saved `sessionKey` again got HTTP 200, for both accounts. So a request does not invalidate the saved login on the server.
- After the test, the app switched to both tested accounts and back (2026-11-12 17:55–17:56). Each switch finished, and none failed its check. So the saved logins still load into Claude.

## 3b. Who sends the request (found while building #47)

Cloudflare challenges some HTTP clients even with valid cookies. Tested on 2026-11-12, without cookies, against the usage request:

| Client | Result |
|---|---|
| System Python 3.9 (`/usr/bin/python3`, which runs the engine) | HTTP 403, `cf-mitigated: challenge` (HTML page) |
| System `curl` 8.7.1 | HTTP 403, `cf-mitigated: challenge` |
| Homebrew Python 3.14 (which ran the spike) | passes (claude.ai's own JSON error) |
| Apple `URLSession` | passes (claude.ai's own JSON error) |

So the engine only decrypts the cookies (`usage-cookies`, password on stdin, output only through the pipe to the app). The **app** sends the request with `URLSession`, in an ephemeral session with no cookie storage and no cache. With the engine's Python, every account got HTTP 403. With `URLSession`, the panel matched the Usage page for 2 accounts.

## 4. Risks

- **Private request.** claude.ai can change or remove it at any time, with no notice. Most of the response is internal code names.
- **Keychain access is the main cost.**
  - "Always Allow" for `/usr/bin/security` would let **any** process on the Mac read the key silently. Never do that.
  - The app (not the Python engine) must read the key with the Keychain API, so that macOS ties the permission to Claude Accounts.
  - The app is ad-hoc signed and not notarized, so macOS may ask again after each update.
- **Cloudflare.** A saved `cf_clearance` cookie ages. An account that is not used for a long time may get a Cloudflare challenge (HTTP 403 with HTML) instead of JSON. The app must show "unknown", not an error.
- **Requests as accounts that are not active.** Each refresh sends one request for each account. At 4 accounts every 10 minutes, that is 24 requests each hour.

## Decision

**Go**, as an opt-in. The switch check in section 3 passed.

- Setting: **Settings → Accounts → "Show live usage from claude.ai"**, off by default. Turning it on explains what is sent and to whom.
- The app reads the Keychain key with the Keychain API, once for each launch. The engine never stores the key or the decrypted cookies, not even in a cache.
- Accounts: only accounts with a saved login. The active account uses the live Claude cookies, so it needs no saved profile.
- Refresh: every 10 minutes, and when the panel opens if the last value is older than 2 minutes. A failure keeps the last value with its age.
- Shown: each entry of `limits` (session, weekly, Fable) with its percent and reset time, per account. An unknown `kind` is shown with its own name, not dropped.
- What is sent where: one GET to claude.ai for each account, with that account's own cookies. Nothing else.

The closed tickets #33–#36 (weekly usage, bars, 90% warning) can be planned again on this source.
