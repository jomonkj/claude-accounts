#!/usr/bin/env python3
"""Spike #39: can the engine read live usage for a saved login? One-off script, not part of the app.

Run it yourself, in your own terminal. macOS asks you to allow access to the
"Claude Safe Storage" Keychain key. The script never prints a cookie, token, email or ID:
only cookie names, the HTTP status, and usage numbers.

    scripts/spikes/usage-live.py --self-test          # checks the decryption, no Keychain, no network
    scripts/spikes/usage-live.py --list               # saved profiles (first 8 characters)
    scripts/spikes/usage-live.py 59f2e10c --dry-run   # decrypts, shows which cookies exist, no network
    scripts/spikes/usage-live.py 59f2e10c             # one GET to claude.ai for that account's usage

It reads a COPY of the saved profile's Cookies database, so the saved login is not changed.
"""
import hashlib, json, os, shutil, sqlite3, subprocess, sys, tempfile, urllib.error, urllib.request

PROFILES = os.path.expanduser("~/Library/Application Support/Claude Account Switcher/profiles")
URL = "https://claude.ai/api/organizations/{org}/usage"
# Cookies sent with the request: the login, the org, and what Cloudflare and the site expect.
SEND = ["sessionKey", "sessionKeyV3", "lastActiveOrg", "cf_clearance", "__cf_bm", "anthropic-device-id",
        "routingHint", "__Host-ant_trusted_device"]
UA = ("Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 (KHTML, like Gecko) "
      "Chrome/138.0.0.0 Safari/537.36")


def chromium_key(password):
    return hashlib.pbkdf2_hmac("sha1", password, b"saltysalt", 1003, 16)


def openssl(args, data):
    r = subprocess.run(["/usr/bin/openssl", "enc", "-aes-128-cbc", "-nosalt", "-iv", "20" * 16] + args,
                       input=data, capture_output=True)
    if r.returncode != 0:
        raise ValueError("decrypt failed")
    return r.stdout


def decrypt(blob, key, db_version):
    """Chromium "v10" value on macOS: AES-128-CBC, IV of 16 spaces. Version 24+ adds a
    32-byte SHA-256 of the host in front of the value."""
    if not blob.startswith(b"v10"):
        raise ValueError("not a v10 value")
    plain = openssl(["-d", "-K", key.hex()], blob[3:])
    return plain[32:] if db_version >= 24 else plain


def read_cookies(db, key):
    """{name: value} of the claude.ai cookies in a copy of the database."""
    with tempfile.TemporaryDirectory() as tmp:
        copy = os.path.join(tmp, "Cookies")
        shutil.copy2(db, copy)
        con = sqlite3.connect(copy)
        try:
            version = int(dict(con.execute("select key, value from meta")).get("version", 0))
            rows = con.execute("select name, encrypted_value from cookies where host_key like '%claude.ai'").fetchall()
        finally:
            con.close()
    out = {}
    for name, blob in rows:
        try:
            out[name] = decrypt(blob, key, version).decode("utf-8")
        except (ValueError, UnicodeDecodeError):
            pass
    return out


def summary(data):
    """Usage numbers only: for each window, utilization and resets_at."""
    lines = []
    if not isinstance(data, dict):
        return [f"response is a {type(data).__name__}, not an object"]
    for k, v in data.items():
        if isinstance(v, dict) and ("utilization" in v or "resets_at" in v):
            lines.append(f"  {k}: utilization={v.get('utilization')} resets_at={v.get('resets_at')}")
        elif isinstance(v, list) and v:
            lines.append(f"  {k}: list of {len(v)}")
            lines += ["    - " + shape(item) for item in v[:10]]
        elif isinstance(v, dict) and v:
            lines.append(f"  {k}: " + shape(v))
        else:
            lines.append(f"  {k}: ({type(v).__name__})")
    return lines


SAFE_TEXT = {"name", "type", "kind", "id", "window", "label", "model", "scope", "unit", "period", "title"}


def shape(v, depth=0):
    """Field names, numbers, booleans and short label texts. Other texts show only as (str),
    so no email, ID or token can be printed."""
    if isinstance(v, dict):
        if depth > 2:
            return "{…}"
        parts = []
        for k, x in v.items():
            if isinstance(x, (int, float, bool)) or x is None:
                parts.append(f"{k}={x}")
            elif isinstance(x, str):
                looks_safe = k in SAFE_TEXT and len(x) <= 40 and "@" not in x and not any(c.isdigit() for c in x[:8])
                parts.append(f"{k}={x}" if looks_safe or k.endswith("_at") else f"{k}=(str)")
            else:
                parts.append(f"{k}={shape(x, depth + 1)}")
        return "{" + ", ".join(parts) + "}"
    if isinstance(v, list):
        return f"[{len(v)} items]" + (" first " + shape(v[0], depth + 1) if v else "")
    return f"({type(v).__name__})"


def self_test():
    key = chromium_key(b"test-password")
    with tempfile.TemporaryDirectory() as tmp:
        db = os.path.join(tmp, "Cookies")
        con = sqlite3.connect(db)
        con.execute("create table meta(key, value)"); con.execute("insert into meta values('version', '24')")
        con.execute("create table cookies(host_key, name, encrypted_value)")
        plain = hashlib.sha256(b".claude.ai").digest() + b"secret-value"
        enc = b"v10" + openssl(["-e", "-K", key.hex()], plain)
        con.execute("insert into cookies values('.claude.ai', 'sessionKey', ?)", (enc,))
        con.execute("insert into cookies values('.example.com', 'other', ?)", (enc,))
        con.commit(); con.close()
        got = read_cookies(db, key)
        wrong = read_cookies(db, chromium_key(b"wrong"))
    # Right key: only the claude.ai cookie, without the host hash. Wrong key: never the value.
    ok = got == {"sessionKey": "secret-value"} and wrong.get("sessionKey") != "secret-value"
    ok = ok and summary({"five_hour": {"utilization": 42, "resets_at": "x"}, "extra": [1]}) == \
        ["  five_hour: utilization=42 resets_at=x", "  extra: list of 1", "    - (int)"]
    # Emails, IDs and tokens in nested fields never print.
    shown = "\n".join(summary({"limits": [{"name": "fable", "utilization": 29, "owner": "a@b.com", "id": "12345678-aa"}],
                               "spend": {"used": 3.5, "token": "sk-secret"}}))
    ok = ok and "name=fable" in shown and "utilization=29" in shown and not any(
        s in shown for s in ("a@b.com", "12345678", "sk-secret"))
    print("self-test:", "passed" if ok else "FAILED")
    return 0 if ok else 1


def main(argv):
    if "--self-test" in argv:
        return self_test()
    profiles = sorted(d for d in os.listdir(PROFILES) if os.path.isfile(os.path.join(PROFILES, d, "Cookies")))
    if "--list" in argv or not [a for a in argv if not a.startswith("--")]:
        print("Saved profiles:", ", ".join(p[:8] for p in profiles))
        return 0
    want = [a for a in argv if not a.startswith("--")][0]
    match = [p for p in profiles if p.startswith(want)]
    if len(match) != 1:
        print("Give the first characters of exactly one profile (see --list).")
        return 2
    print(f"profile {match[0][:8]}: asking macOS for the Claude Safe Storage key (allow it in the dialog)")
    r = subprocess.run(["/usr/bin/security", "find-generic-password", "-w", "-s", "Claude Safe Storage"],
                       capture_output=True)
    if r.returncode != 0:
        print("No access to the Keychain key. Nothing was read.")
        return 1
    cookies = read_cookies(os.path.join(PROFILES, match[0], "Cookies"), chromium_key(r.stdout.strip()))
    print("decrypted cookies:", ", ".join(sorted(cookies)) or "none (wrong key or no claude.ai cookies)")
    if "sessionKey" not in cookies or "lastActiveOrg" not in cookies:
        print("sessionKey or lastActiveOrg is missing. Stop.")
        return 1
    if "--dry-run" in argv:
        print("dry run: no request sent.")
        return 0
    header = "; ".join(f"{n}={cookies[n]}" for n in SEND if n in cookies)
    req = urllib.request.Request(URL.format(org=cookies["lastActiveOrg"]),
                                 headers={"Cookie": header, "User-Agent": UA, "Accept": "application/json"})
    try:
        with urllib.request.urlopen(req, timeout=20) as resp:
            status, body = resp.status, resp.read()
    except urllib.error.HTTPError as e:
        status, body = e.code, e.read()
    except urllib.error.URLError as e:
        print("network error:", e.reason)
        return 1
    print("HTTP status:", status)
    try:
        print("\n".join(summary(json.loads(body))))
    except ValueError:
        print("not JSON; first 120 characters:", body[:120].decode("utf-8", "replace").replace("\n", " "))
    return 0 if status == 200 else 1


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
