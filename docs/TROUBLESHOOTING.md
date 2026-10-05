# Troubleshooting

Every failure mode hit during a real session, with the actual cause.

---

## `401` on the public URL

**First question: which layer rejected you?**

```bash
curl -s -D - -o /dev/null https://<workspace>-<id>-18789.nebula.me/
```

### With `x-nebula-gate: unauthenticated`

Platform gate. **Not your gateway token.** Log in at:

```
https://www.nebula.gg/login
```

The `login_url` inside the JSON body points at `/tunnel-gate/login`, which is a
dead path:

```
nebula.gg/tunnel-gate/login        → 307 → www.nebula.gg/tunnel-gate/login
www.nebula.gg/tunnel-gate/login    → 307 → www.nebula.gg/     (marketing page, no form)
www.nebula.gg/login                → 200  → <title>Sign In | Nebula</title>
```

Rotating `gateway.auth.token` will never fix this. The request never reaches the
gateway.

The 401 also clears the gate cookie on every attempt:

```
set-cookie: __Host-nebula_gate=; Max-Age=0
```

That is the gate actively rejecting, not a missing cookie.

### Without `x-nebula-gate`

The gateway rejected you. Use the `#token=` URL, not `?token=`

### Dummy credential probes are useless

All of these return the same `gate_unauthenticated`:

```
Authorization: Bearer <anything>
Cookie: __Host-nebula_gate=<anything>
X-Nebula-Gate-Token: <anything>
```

The gate does not accept a bearer token or a hand-made header. It wants a session
cookie from an interactive login. Don't try to synthesise one.

---

## "The browser could not reach \<host\>"

**Not a credentials problem.** The request never completed.

Read the message: *"Check the address and transport before retrying credentials."*
It is telling you the truth — check transport first.

An HTTP status (even `401`) means DNS, TLS, and routing all worked and only auth
remains. A `000` or timeout means nothing arrived.

Check on your machine:

```bash
nslookup <workspace>-<id>-18789.nebula.me
curl -s -o /dev/null -w "%{http_code}\n" https://<workspace>-<id>-18789.nebula.me/
```

Common culprits: VPN toggled, proxy extension, corporate DNS, IPv6 route dropped.

**Diagnostic that isolates it:** if it used to work and stopped without any box
change, the box is almost certainly not the cause. Sandbox hostnames can also be
re-provisioned by the platform, which changes them.

---

## Curl inside the sandbox returns `000`

**Expected. Not a bug.** The sandbox cannot reach its own public hostname — the
request exits to the platform edge and returns via a path that does not loop back
to the origin.

Verify the gateway directly instead:

```bash
curl -s -w "\nHTTP_CODE:%{http_code}\n" http://127.0.0.1:18789/health
```

Time spent debugging this is wasted time.

---

## Bootstrap token stopped working

Expire ho gaya. They are single-use with a 10-minute TTL:

```bash
openclaw dashboard --json --no-open | grep -o 'browserBootstrapExpiresAtMs":[0-9]*'
date -u -d @<seconds>      # compare to now
```

Mint a fresh one. This is normal expiry, not a broken install.

The gateway token in `url` is the long-lived one — for anything beyond quick
onboarding, use that.

---

## `sessionStorage` and "it logged me out"

Expected. The Control UI keeps the token in `sessionStorage`, scoped to the
current tab and selected gateway URL. Closing the tab drops it. No
`localStorage` persistence by design.

The same tab refreshing keeps working. Opening a **new** tab needs the token URL
again.

---

## Pairing request never appears

```bash
openclaw devices list
```

If nothing is pending, the browser never completed the initial handshake. That
usually means the gate blocked it before the gateway saw it — see the gate
section above.

Pending DM pairing requests are capped per channel account. A few stale pending
requests can crowd out a new one.

---

## Approved the device, still unauthorized

```bash
openclaw status --all
```

Check whether the browser is authenticating with the right gateway URL. When
`gatewayUrl` points at a different gateway, the UI does **not** fall back to local
config or environment credentials.

Rotate the device token if mismatch persists:

```bash
openclaw devices rotate --device <id> --role operator
```

---

## My noVNC URL looks right but it is a different box

Check the hostname shape. Nebula sandboxes use:

```
<workspace>-<id>-<port>.nebula.me
```

Daytona sandboxes use a different domain entirely:

```
<port>-<uuid>.daytonaproxy01.net
```

Also compare credentials — a password that looks plausible can still belong to a
different machine. Cross-check:

```bash
hostname
cat /etc/cloudflared/config.yml | grep hostname
which daytona    # absent on Nebula
```

---

## `allowedOrigins` / whitelist

Only add origins if you see an **explicit origin error**. A `401` means the
gateway already accepted the origin and asked for credentials.

When `gateway.publicOrigin` is set and matches what you are browsing, there is
nothing to whitelist. This step is a Daytona pattern; on Nebula the platform
already writes `publicOrigin`.

---

## Config change did not take effect

```bash
kill -USR1 "$(pgrep -f openclaw-gateway | head -1)"
pgrep -f openclaw-gateway | head -1        # must be the SAME pid
curl -s http://127.0.0.1:18789/health
```

Same PID means reload worked. A changed PID means it restarted — and a restart
can break Telegram's long-poll into a duplicate-poller error.

If a reload does not pick up a change, some settings are captured in a
startup snapshot. Restart, and expect the Telegram blip.

---

## Editing config safely

Always back up with a timestamp:

```bash
cp ~/.openclaw/openclaw.json ~/.openclaw/openclaw.json.bak.$(date +%Y%m%d%H%M%S)
openclaw config validate
```

Prefer the official setters — they handle shape correctly:

```bash
openclaw config set <key> <value>
openclaw config get <key>
```

A wrong-shaped value can be accepted by the file and still be ignored at runtime.
Reading config from the schema settles it:

```bash
openclaw config schema | grep -i <key>
```