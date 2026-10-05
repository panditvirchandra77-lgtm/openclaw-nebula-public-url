# 🌐 Nebula Sandbox + OpenClaw: Public Control UI URL

How to get a publicly reachable OpenClaw Control UI from inside a Nebula sandbox —
and how to debug it when it stops working.

**Tested on:** Nebula sandbox `1.0.55`, OpenClaw `2026.9.7`, cloudflared `2026.9.3`,
Debian 13, gateway port `18789`.

---

## ⚠️ Read this first: there is no "native" public URL

OpenClaw has **no built-in public URL feature.** There is no `openclaw tunnel`,
no `openclaw serve`, no `openclaw share`. I checked the full CLI command list and
the docs — they don't exist.

What actually happens is three separate layers:

```
[browser] → [nebula.me edge] → [cloudflared tunnel] → [localhost:18789 OpenClaw gateway]
             ↑ layer 1: gate       ↑ layer 2: tunnel      ↑ layer 3: gateway auth
             (browser login)        (platform-managed)      (token in URL fragment)
```

The platform provides the tunnel and the hostname. **You configure only layer 3.**
Getting this wrong is the single most common source of confusion, so this guide
leads with it.

---

## 🧠 Mental model

Your sandbox has **no public IP and no open ports.** Every inbound request must go
through the platform's tunnel. So you are not "exposing port 18789" — you are
telling the platform's proxy which local port your service lives on, then teaching
OpenClaw to trust that public origin.

Two auth layers sit in front of your app:

| Layer | Who owns it | What you configure |
|---|---|---|
| `nebula.me` gate | Platform | Nothing — log in with your Nebula account |
| OpenClaw gateway token | You | `gateway.auth.token` |

**Requests die at the gate before the gateway ever sees them.** See
[Troubleshooting](#-troubleshooting) — this is why rotating your token fixes nothing.

---

## 📋 What you need

- Nebula sandbox with OpenClaw installed (gateway listening on `18789`)
- Shell access to the sandbox
- Nebula account login in your browser (for the gate)

---

## 🚀 Setup

### 1. Confirm the gateway is up

```bash
curl -s -w "\nHTTP_CODE:%{http_code}\n" http://127.0.0.1:18789/health
# {"ok":true,"status":"live"}
# HTTP_CODE:200
```

If this fails, OpenClaw isn't running. Fix that first — everything else is moot.

### 2. Read the public origin the platform gave you

```bash
openclaw config get gateway.publicOrigin
# "https://<workspace>-<id>-18789.nebula.me"
```

Already set by the platform. You normally don't need to touch it.

Check the rest of the gateway config:

```bash
openclaw config get gateway
```

You want to see:

```json
{
  "port": 18789,
  "bind": "lan",
  "auth": { "mode": "token" },
  "trustedProxies": ["127.0.0.1", "::1"],
  "publicOrigin": "https://<workspace>-<id>-18789.nebula.me"
}
```

- `bind: "lan"` — **required.** Loopback-only cannot be reached through the tunnel.
- `trustedProxies` — the tunnel connects from localhost, so the gateway needs this
  to trust forwarded-for headers.

### 3. Verify the tunnel ingress

```bash
cat /etc/cloudflared/config.yml
```

```yaml
tunnel: <tunnel-uuid>
credentials-file: /etc/cloudflared/credentials.json
ingress:
  - hostname: <workspace>-<id>-18789.nebula.me
    service: http://localhost:18789
  # ... other services ...
  - service: http_status:404     # catch-all — no wildcard host routing
```

That catch-all `404` matters: unknown hostnames get a clean 404 instead of being
routed somewhere unexpected.

### 4. Get your dashboard URL with token

```bash
openclaw dashboard --json --no-open
```

Returns two different URLs:

| Field | Value | Lifetime |
|---|---|---|
| `url` | `http://127.0.0.1:18789/#token=<gateway-token>` | long-lived |
| `browserUrl` | `.../#bootstrapToken=<one-time>&bootstrapProfile=owner&...` | **single-use, 10 min** |

Use the `url` token, swapped onto your **public** hostname:

```
https://<workspace>-<id>-18789.nebula.me/#token=<gateway-token>
```

> **Why `#token=` and not `?token=`?** URL fragments don't enter HTTP request logs
> or `Referer` headers. A query string does. Always prefer the fragment.

### 5. Approve the pairing

The first browser connection creates a pending device request:

```bash
openclaw devices list        # look under "Pending"
openclaw devices approve <request-id>
```

**Check the IP before approving.** The listing shows the requesting address. A
public IPv6 address you don't recognise is not your browser — don't approve it.

Approval is per browser. New browser or cleared profile = new pending request.

### 6. Open it

Log in at `https://www.nebula.gg/login`, then open your `#token=` URL.
Refresh once after approving — an already-open page stays on its old error.

---

## 🔐 Security notes

- **Rotate the token after sharing it.** `#token=` grants full operator access:
  config changes, approvals, and device pairing. If the URL has been forwarded or
  pasted anywhere, rotate:

  ```bash
  openclaw config set gateway.auth.token <new-token>
  kill -USR1 "$(pgrep -f openclaw-gateway | head -1)"   # reload, don't restart
  ```

- **Bootstrap tokens expire in 10 minutes and are single-use.** A dead bootstrap
  link is normal — mint a new one. It is not a broken install.
- **The Control UI stores the token in `sessionStorage`**, scoped to the tab.
  Closing the tab drops it. That is expected, not a bug.
- **Never commit a real hostname, tunnel UUID, or token.** These identify a live
  workspace. This repo uses placeholders everywhere for that reason.

---

## 🔧 Troubleshooting

### `401` with `gate_unauthenticated`

The platform gate is rejecting you. Look for the header:

```bash
curl -s -D - -o /dev/null https://<workspace>-<id>-18789.nebula.me/
```

```json
{
  "error": "gate_unauthenticated",
  "login_url": "https://nebula.gg/tunnel-gate/login?...",
  "gate": "denied"
}
```

**Fix:** log in at **`https://www.nebula.gg/login`**.

Note the correct path. The `login_url` field points at `/tunnel-gate/login`, which
redirects (307 → 307) to the marketing homepage and renders no form at all. The
real sign-in page is `/login`. Following the `login_url` blindly is a dead end.

Confirm which layer rejected you:

```bash
curl -s -D - -o /dev/null https://<workspace>-<id>-18789.nebula.me/ | grep -i x-nebula-gate
# x-nebula-gate: unauthenticated   → platform gate, nothing to do with your token
```

### `401` without `x-nebula-gate`

That header is absent, so the **gateway** rejected you. Use the `#token=` URL.

### "The browser could not reach \<host\>"

Not a credential problem — the request never completed. Check DNS and transport on
*your* machine first: VPN, proxy extension, corporate DNS, IPv6 routing.

```bash
nslookup <workspace>-<id>-18789.nebula.me
curl -s -o /dev/null -w "%{http_code}\n" https://<workspace>-<id>-18789.nebula.me/
```

An HTTP code (even `401`) means the host is reachable and only auth remains. A
`000` or timeout means it never arrived.

### Curl inside the sandbox returns `000` or exit 28

**This is normal.** The sandbox cannot reach its own public hostname — that path
loops back through the platform's edge. Don't debug it; test from a real browser.

### Bootstrap link stopped working

Expire ho gaya. `browserBootstrapExpiresAtMs` in the `dashboard --json` output gives
the expiry timestamp. Mint a fresh one.

### `allowedOrigins` / whitelist steps

Not needed when `gateway.publicOrigin` is already set and you get a `401` rather
than an origin rejection. A `401` means the gateway accepted the origin and asked
for credentials. Only add origins if you see an explicit origin error.

---

## 📚 More

- [`docs/ARCHITECTURE.md`](docs/ARCHITECTURE.md) — how the three layers actually fit together
- [`docs/TROUBLESHOOTING.md`](docs/TROUBLESHOOTING.md) — every error and its real cause
- [`scripts/check-setup.sh`](scripts/check-setup.sh) — one-shot health check for your sandbox
- [`examples/openclaw-snippet.json`](examples/openclaw-snippet.json) — the exact expected config

---

## 🧾 Provenance

Written from a real debugging session on a Nebula sandbox. Everything here was
verified against a live gateway, not copied from docs.

Corrections made along the way, kept in because they're the traps:

- There is no "native" public URL. The hostname and tunnel come from the platform.
- The `401` from the public hostname is the **platform gate**, not the gateway.
  Rotating the gateway token does not affect it.
- The `login_url` in the gate error points at a dead path. Real login is `/login`.
- A noVNC URL with a `daytonaproxy01.net` hostname is a **different sandbox on a
  different platform**, even if the password looks right.

## 📄 License

MIT