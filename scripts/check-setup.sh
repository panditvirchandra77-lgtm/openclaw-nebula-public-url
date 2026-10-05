#!/usr/bin/env bash
# Health check for an OpenClaw gateway behind a Nebula public URL.
# Read-only: changes nothing, prints a verdict per check.
#
#   ./check-setup.sh [public-hostname]
#
# With no argument it auto-detects the hostname from gateway.publicOrigin.

set -uo pipefail

GATEWAY_PORT="${GATEWAY_PORT:-18789}"
OK=0; WARN=0; FAIL=0

say()  { printf '\n\033[1m%s\033[0m\n' "$*"; }
pass() { printf '  \033[32mPASS\033[0m  %s\n' "$*"; OK=$((OK+1)); }
warn() { printf '  \033[33mWARN\033[0m  %s\n' "$*"; WARN=$((WARN+1)); }
bad()  { printf '  \033[31mFAIL\033[0m  %s\n' "$*"; FAIL=$((FAIL+1)); }
info() { printf '        %s\n' "$*"; }

# OpenClaw often needs a newer node than the default PATH resolves.
# A too-old node makes `openclaw config get` fail silently with an empty result,
# so put /usr/bin first when it has the newer one.
if [ -x /usr/bin/node ] && [ -x /usr/local/bin/node ]; then
  _usr="$(/usr/bin/node -v 2>/dev/null)"
  _loc="$(/usr/local/bin/node -v 2>/dev/null)"
  case "$_usr:$_loc" in
    *.*:v1?.*|*.*:v?.*) : ;;
  esac
  _major() { echo "$1" | sed -E 's/^v([0-9]+).*/\1/'; }
  if [ "$(_major "$_usr")" -gt "$(_major "$_loc")" ]; then
    export PATH="/usr/bin:$PATH"
  fi
fi

if ! command -v openclaw >/dev/null 2>&1; then
  info "openclaw not on PATH; trying ~/.local/bin"
  export PATH="$HOME/.local/bin:$PATH"
fi
if [ -x /usr/bin/node ] && [ -x /usr/local/bin/node ]; then
  if [ "$(/usr/local/bin/node -v 2>/dev/null)" != "$(/usr/bin/node -v 2>/dev/null)" ]; then
    warn "two node versions present"
    info "/usr/bin/node        -> $(/usr/bin/node -v)"
    info "/usr/local/bin/node  -> $(/usr/local/bin/node -v)"
    info "using: $(command -v node) -> $(node -v)"
  fi
fi

# ---------------------------------------------------------------- local
say "1. Gateway reachable on loopback"
health="$(curl -s -m 5 "http://127.0.0.1:${GATEWAY_PORT}/health")"
if echo "$health" | grep -q '"ok":true'; then
  pass "gateway healthy — $health"
else
  bad "gateway not responding on 127.0.0.1:${GATEWAY_PORT}"
  info "OpenClaw is probably not running. Everything below is moot."
  printf '\n%d passed, %d warnings, %d failed\n' "$OK" "$WARN" "$FAIL"
  exit 1
fi

# ---------------------------------------------------------------- config
say "2. Gateway config"
cfg="$(openclaw config get gateway 2>/dev/null)"
if [ -z "$cfg" ]; then
  warn "could not read gateway config"
else
  echo "$cfg" | grep -q '"bind"[[:space:]]*:[[:space:]]*"lan"' \
    && pass 'bind = "lan" (required for tunnel reachability)' \
    || bad 'bind is not "lan" — the tunnel may not reach the gateway'

  echo "$cfg" | grep -q '"mode"[[:space:]]*:[[:space:]]*"token"' \
    && pass 'auth.mode = "token"' \
    || warn 'auth.mode is not "token"'

  echo "$cfg" | grep -q 'publicOrigin' \
    && pass "publicOrigin set: $(echo "$cfg" | grep -o '"publicOrigin"[^,}]*')" \
    || warn "publicOrigin not set — you may be hitting the wrong hostname"

  echo "$cfg" | grep -q 'trustedProxies' \
    && pass "trustedProxies: $(echo "$cfg" | grep -o '"trustedProxies"[^]]*]')" \
    || warn "trustedProxies not set — tunnel requests come from localhost"
fi

# ---------------------------------------------------------------- tunnel
say "3. Tunnel ingress"
CF=/etc/cloudflared/config.yml
if [ -r "$CF" ]; then
  pass "found $CF"
  grep -q "localhost:${GATEWAY_PORT}" "$CF" \
    && pass "ingress routes to localhost:${GATEWAY_PORT}" \
    || bad "no ingress rule pointing at localhost:${GATEWAY_PORT}"
  grep -q 'http_status:404' "$CF" \
    && pass "catch-all 404 present (no wildcard host routing)" \
    || warn "no catch-all 404 — unknown hostnames may route unexpectedly"
else
  warn "no readable $CF (not a Nebula sandbox, or tunnel is elsewhere)"
fi

# ---------------------------------------------------------------- hostname
if [ -n "${1:-}" ]; then
  HOST="$1"
else
  HOST="$(openclaw config get gateway.publicOrigin 2>/dev/null \
          | grep -oE 'https?://[^"]+' | sed -E 's#https?://##; s#/.*##')"
fi

say "4. Public hostname"
if [ -z "$HOST" ]; then
  warn "could not detect hostname — pass it as: $0 <hostname>"
  printf '\n%d passed, %d warnings, %d failed\n' "$OK" "$WARN" "$FAIL"
  exit 0
fi
info "testing $HOST"

body="$(curl -s -m 12 -D /tmp/_hdr "https://$HOST/" 2>/dev/null)"
code="$(head -1 /tmp/_hdr 2>/dev/null | awk '{print $2}')"
gate_hdr="$(grep -i '^x-nebula-gate' /tmp/_hdr 2>/dev/null | tr -d '\r')"
rm -f /tmp/_hdr

if echo "$body" | grep -q 'gate_unauthenticated'; then
  warn "PLATFORM GATE rejected you (not your gateway token)"
  info "log in at: https://www.nebula.gg/login"
  info "note: the login_url in this error points at a dead path."
  info "rotating gateway.auth.token will NOT help."
elif [ "$code" = "200" ]; then
  pass "public URL returns 200 — reachable"
elif [ "$code" = "401" ]; then
  pass "public URL returns 401 — reachable, auth required (expected)"
else
  bad "public URL returned '${code:-no response}'"
  info "000/timeout from inside the sandbox is normal."
  info "test from a real browser or another machine."
fi
[ -n "$gate_hdr" ] && info "$gate_hdr"

# ---------------------------------------------------------------- summary
printf '\n\033[1mSummary\033[0m  %d passed, %d warnings, %d failed\n' "$OK" "$WARN" "$FAIL"
if [ "$FAIL" -eq 0 ]; then
  printf 'Next: openclaw dashboard --json --no-open  ->  use the #token= URL\n'
else
  printf 'Fix the FAIL lines above before debugging anything else.\n'
fi