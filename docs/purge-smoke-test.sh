#!/usr/bin/env bash
#
# purge-smoke-test.sh — A2 Content-Refresh purge verification (Contract G15)
# ==========================================================================
#
#   recipes4nuxt SSHIPS THIS AS A TEMPLATE. It is NOT run by the deploy gem and
#   the gem cannot run it for you: there is NO purge endpoint inside the gem —
#   the `server/api/_purge` route is FE/Layer code (Luke revier, Contract §6a).
#   ➜  YOU (the consumer) wire it up against YOUR running Nitro instance + YOUR
#      purge endpoint. This script is the harness; you supply the endpoint.
#
# WHAT IT VERIFIES (the A2 risk — nuxt#20495):
#   The purge clears a routeRules `swr` cache via an INTERNAL/UNDOCUMENTED Nitro
#   storage-key prefix (`nitro:routes:…`). The verified mechanic enumerates the
#   keys with `getKeys('nitro')` and `removeItem()`s each one — NOT `clear(prefix)`,
#   which silently no-ops on the colon-namespaced keys (HTTP 200, cache stale).
#   A Nitro/unstorage upgrade can change that key schema and make the purge
#   silently no-op. This test proves, against YOUR pinned Nitro version, that the
#   purge REALLY invalidates the cache (cached response → purge → fresh response),
#   so a version bump can't regress it unnoticed. Run it after every Nuxt/Nitro
#   bump. (Reference endpoint impl.: nuxt3_layer server/api/_purge.post.ts.)
#
# HOW THE CHECK WORKS:
#   1. Hit a swr-cached content route twice → the 2nd hit is served from cache
#      (we detect this via an X-Nitro-Cache: HIT header if your app sets one,
#      OR via a body marker that only changes on a real re-render — see below).
#   2. Change the upstream data (or just wait so a re-render would differ), then
#      POST your purge endpoint.
#   3. Hit the route again → it MUST re-render fresh (cache MISS / new marker).
#
# DETECTION MODE (pick one, export before running):
#   PURGE_DETECT=header   → relies on a cache-status response header
#                           (set X-Nitro-Cache / X-Cache in your handler).
#   PURGE_DETECT=marker   → relies on a body marker that changes per render
#                           (e.g. an ISO timestamp injected server-side). DEFAULT.
#
# REQUIRED ENV (no defaults for the app-specific bits — fail loud if unset):
#   PURGE_BASE_URL    e.g. http://127.0.0.1:3500     (= nuxt3_ssr_host:nuxt3_ssr_port)
#   PURGE_ROUTE       a swr-cached content route, e.g. /            (default "/")
#   PURGE_ENDPOINT    your purge route,            e.g. /api/_purge (default)
#   PURGE_TOKEN       the auth token (= NUXT_PURGE_TOKEN in nuxt3_ssr.env)
#   PURGE_DETECT      header | marker                               (default marker)
#   PURGE_HEADER      cache-status header name      (default X-Nitro-Cache)
#   PURGE_MARKER_RE   regex extracting the per-render marker from the body
#                     (default: an ISO-8601 timestamp)
#
# EXIT: 0 = purge verified · 1 = purge did NOT invalidate (G15 risk realized!) ·
#       2 = misconfig / endpoint unreachable.
#
# ── example ───────────────────────────────────────────────────────────────
#   PURGE_BASE_URL=http://127.0.0.1:3500 \
#   PURGE_ENDPOINT=/api/_purge PURGE_TOKEN=s3cr3t \
#   PURGE_DETECT=header PURGE_HEADER=X-Nitro-Cache \
#   ./docs/purge-smoke-test.sh
# ───────────────────────────────────────────────────────────────────────────

set -u

BASE="${PURGE_BASE_URL:-}"
ROUTE="${PURGE_ROUTE:-/}"
ENDPOINT="${PURGE_ENDPOINT:-/api/_purge}"
TOKEN="${PURGE_TOKEN:-}"
DETECT="${PURGE_DETECT:-marker}"
HEADER="${PURGE_HEADER:-X-Nitro-Cache}"
MARKER_RE="${PURGE_MARKER_RE:-[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}}"

die()  { echo "❌ $*" >&2; exit 2; }
fail() { echo "❌ $*" >&2; exit 1; }
ok()   { echo "✅ $*"; }

[ -n "$BASE" ]  || die "PURGE_BASE_URL is required (= nuxt3_ssr_host:nuxt3_ssr_port, e.g. http://127.0.0.1:3500)."
command -v curl >/dev/null || die "curl not found."

ROUTE_URL="${BASE%/}${ROUTE}"
PURGE_URL="${BASE%/}${ENDPOINT}"

echo "── A2 purge smoke-test (G15) ───────────────────────────────"
echo "   route   : $ROUTE_URL"
echo "   purge   : $PURGE_URL"
echo "   detect  : $DETECT"
echo

# --- helpers ---------------------------------------------------------------
fetch_header() {  # $1 = header name → prints its value (lowercased name match)
  curl -fsS -D - -o /dev/null --max-time 10 "$ROUTE_URL" 2>/dev/null \
    | tr -d '\r' | awk -v h="$(echo "$1" | tr '[:upper:]' '[:lower:]')" \
        'BEGIN{IGNORECASE=1} tolower($1)==h":"{ $1=""; sub(/^ /,""); print }'
}
fetch_marker() {  # prints the per-render marker found in the body (first match)
  curl -fsS --max-time 10 "$ROUTE_URL" 2>/dev/null | grep -Eo "$MARKER_RE" | head -n1
}
do_purge() {
  local code
  code=$(curl -fsS -o /dev/null -w '%{http_code}' --max-time 10 \
           -X POST -H "x-purge-token: ${TOKEN}" "$PURGE_URL" 2>/dev/null) || true
  echo "$code"
}

# --- 0. reachability -------------------------------------------------------
curl -fsS -o /dev/null --max-time 10 "$ROUTE_URL" \
  || die "Route $ROUTE_URL unreachable — is Nitro up on nuxt3_ssr_host:port? (cap <stage> nuxt3:ssr:check_status)"

# --- 1. warm the cache (2 hits) → 2nd should be a cache HIT -----------------
curl -fsS -o /dev/null --max-time 10 "$ROUTE_URL" || die "warm-up request failed"

if [ "$DETECT" = "header" ]; then
  HSTATE="$(fetch_header "$HEADER")"
  [ -n "$HSTATE" ] || die "No '$HEADER' header on $ROUTE_URL — set it in your handler, or use PURGE_DETECT=marker."
  echo "   cache header after warm-up: $HEADER: $HSTATE"
  echo "$HSTATE" | grep -qi 'HIT' || echo "   ⚠️  expected a HIT after warm-up (swr TTL may be 0 / route not cached?)"
  BEFORE="$HSTATE"
else
  BEFORE="$(fetch_marker)"
  [ -n "$BEFORE" ] || die "No marker matched /$MARKER_RE/ in body — inject a per-render marker, or set PURGE_MARKER_RE / use PURGE_DETECT=header."
  echo "   cached render marker: $BEFORE"
  # a 2nd hit must return the SAME marker (served from cache, not re-rendered)
  AGAIN="$(fetch_marker)"
  [ "$AGAIN" = "$BEFORE" ] || echo "   ⚠️  marker changed without a purge — route may not be cached (swr) at all."
fi

# --- 2. purge --------------------------------------------------------------
echo
echo "→ purging $PURGE_URL …"
CODE="$(do_purge)"
case "$CODE" in
  2??) ok "purge endpoint responded $CODE" ;;
  401|403) fail "purge endpoint rejected the token ($CODE) — check PURGE_TOKEN == NUXT_PURGE_TOKEN in nuxt3_ssr.env." ;;
  000|"") die "purge endpoint $PURGE_URL unreachable — is server/api/_purge wired up? (FE/Layer, not the gem)" ;;
  *) fail "purge endpoint returned unexpected $CODE" ;;
esac

# Give Nitro a tick to clear + re-render lazily on the next request.
sleep 1

# --- 3. verify invalidation ------------------------------------------------
echo
if [ "$DETECT" = "header" ]; then
  AFTER="$(fetch_header "$HEADER")"
  echo "   cache header after purge: $HEADER: $AFTER"
  if echo "$AFTER" | grep -qi 'MISS'; then
    ok "PURGE VERIFIED — first post-purge request is a cache MISS (re-rendered fresh)."
    exit 0
  fi
  fail "PURGE DID NOT INVALIDATE — header still '$AFTER' (expected MISS). G15 risk realized: re-pin Nitro / inspect the actual keys via getKeys('nitro') (prefix nitro:routes:…; do NOT use clear(prefix) — it no-ops, nuxt#20495)."
else
  AFTER="$(fetch_marker)"
  echo "   render marker after purge: $AFTER"
  if [ -n "$AFTER" ] && [ "$AFTER" != "$BEFORE" ]; then
    ok "PURGE VERIFIED — render marker changed ($BEFORE → $AFTER): the cache was really cleared."
    exit 0
  fi
  fail "PURGE DID NOT INVALIDATE — marker unchanged ('$BEFORE'). G15 risk realized: the routeRules purge no-op'd. Re-pin Nitro / inspect the actual keys via getKeys('nitro') (prefix nitro:routes:…; do NOT use clear(prefix) — it no-ops, nuxt#20495)."
fi
