# Architecture: how the public URL actually works

## Three layers, one request

```
   browser
      │  https://<workspace>-<id>-18789.nebula.me/#token=...
      ▼
┌─────────────────────────────────────┐
│ Layer 1 — nebula.me edge (platform)│
│ Cloudflare-fronted                 │
│ Checks a session cookie            │
│ Emits x-nebula-gate: unauthenticated
│ Emits gate_unauthenticated + login_url
└──────────────┬──────────────────────┘
               │ HTTP (from tunnel ingress, localhost)
               ▼
┌─────────────────────────────────────┐
│ Layer 2 — cloudflared tunnel       │
│ Managed by the platform            │
│ Ingress rules in                   │
│   /etc/cloudflared/config.yml       │
│ Maps hostname → localhost:18789    │
│ Runs as its own process             │
└──────────────┬──────────────────────┘
               │ HTTP to 127.0.0.1:18789
               ▼
┌─────────────────────────────────────┐
│ Layer 3 — OpenClaw gateway         │
│ token auth (gateway.auth.mode)     │
│ Serves Control UI + WebSocket      │
│ Port 18789                         │
└─────────────────────────────────────┘
```

**You only configure layer 3.** Layers 1 and 2 are provisioned by the platform
when the sandbox is created.

## Why the 401 misleads you

A `401` from the public hostname tells you almost nothing on its own. Two very
different layers both return it:

| Signal | Meaning | Whose credential |
|---|---|---|
| `x-nebula-gate: unauthenticated` header present | Layer 1 rejected you | Platform account login |
| No such header | Layer 3 rejected you | `gateway.auth.token` |

The gate response also carries a JSON body:

```json
{
  "error": "gate_unauthenticated",
  "login_url": "https://nebula.gg/tunnel-gate/login?...",
  "gate": "denied"
}
```

**The `login_url` is a trap.** That path 307-redirects twice and lands on the
marketing homepage with no form. The real sign-in page is:

```
https://www.nebula.gg/login
```

Always check the `x-nebula-gate` header before touching your gateway token.
Rotating `gateway.auth.token` cannot fix a layer-1 rejection.

## Bind mode and trusted proxies

```json
"bind": "lan"
```

Loopback-only binding means the tunnel (which connects from inside the box)
still works, but anything relying on a LAN address does not. In practice the
platform expects `lan` here.

```json
"trustedProxies": ["127.0.0.1", "::1"]
```

cloudflared connects from localhost, so the gateway sees loopback-sourced
requests. Without trusted proxies it either rejects them or loses the original
client address — which is what device pairing approval shows you.

## Two credential types, different lifetimes

`openclaw dashboard --json --no-open` returns both:

```json
{
  "url": ".../#token=<gateway-token>",
  "browserUrl": ".../#bootstrapToken=<one-time>&bootstrapProfile=owner&...",
  "browserBootstrapExpiresAtMs": 1791210476103
}
```

| | `token` | `bootstrapToken` |
|---|---|---|
| Lifetime | long-lived | 10 minutes |
| Uses | single | single |
| Grants | full operator | pairing handoff |
| Where stored | `sessionStorage` (tab-scoped) | same, then discarded |

A bootstrap link dying is **normal expiry**, not a fault. Check
`browserBootstrapExpiresAtMs` before assuming breakage.

## Device pairing

The first browser connection to a new profile registers a pending device:

```
Pending (1)
┌──────────────┬──────────────┬───────────────┐
│ Request      │ Device       │ Status        │
├──────────────┼──────────────┼───────────────┤
│ <uuid>       │ <device-id>  │ new pairing   │
└──────────────┴──────────────┴───────────────┘
```

Approve with `openclaw devices approve <request-id>`.

The listing shows the requesting IP. **Read it before approving** — pairing grants
operator scopes including `operator.admin`, `operator.pairing`, and
`operator.approvals`. That is full control over the gateway.

Control UI devices typically receive:

```
operator.admin, operator.read, operator.write,
operator.approvals, operator.pairing, operator.questions
```

## Where the sandbox cannot test itself

A curl from inside the sandbox to its own public hostname returns `000` or times
out (curl exit 28). This is **expected**: the request exits to the platform edge
and comes back through a path that does not loop cleanly to the origin.

Test public reachability from a real browser or a different machine. Inside the
sandbox, test the gateway directly:

```bash
curl -s http://127.0.0.1:18789/health
```

## Reload vs restart

After editing config, reload rather than restart:

```bash
kill -USR1 "$(pgrep -f openclaw-gateway | head -1)"
```

Verify the PID is unchanged afterwards — a restart breaks Telegram's long-poll and
can produce a duplicate-poller error.

```bash
pgrep -f openclaw-gateway | head -1     # same PID = reload worked
curl -s http://127.0.0.1:18789/health
```

## Not OpenClaw's job

OpenClaw provides **no** native tunnel or share command. If you need a public URL,
something in front must terminate and forward. On Nebula that is the platform's
cloudflared tunnel; elsewhere it may be Tailscale Serve, your own reverse proxy,
or an SSH tunnel:

```bash
ssh -N -L 18789:127.0.0.1:18789 user@host
```

All of them present the same Control UI at `http://127.0.0.1:18789/` locally.