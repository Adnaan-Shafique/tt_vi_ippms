#!/usr/bin/env bash
# ══════════════════════════════════════════════════════════════════════════
#  preflight.sh — verify 10.19.75.115 can actually run this before migrating
#
#    deploy/preflight.sh /etc/ippms-assistant/ippms-prod.env
#
#  Read-only. Checks every external dependency the app has. Run it BEFORE
#  moving anything — the expensive failure mode is discovering the gateway is
#  unreachable after you have already cut over.
# ══════════════════════════════════════════════════════════════════════════
set -uo pipefail

ENV_FILE="${1:-/etc/ippms-assistant/ippms-prod.env}"
FAIL=0
pass() { printf '  \033[32m✓\033[0m %s\n' "$*"; }
fail() { printf '  \033[31m✗\033[0m %s\n' "$*"; FAIL=1; }
warn() { printf '  \033[33m!\033[0m %s\n' "$*"; }

[[ -r "$ENV_FILE" ]] || { echo "cannot read $ENV_FILE"; exit 1; }
set -a; . "$ENV_FILE"; set +a

echo; echo "── secrets ─────────────────────────────────────────────"
[[ -n "${IG_DB_PASSWORD:-}" ]] && pass "IG_DB_PASSWORD set" || fail "IG_DB_PASSWORD empty — no source fallback exists, DB calls will fail"
[[ -n "${GPU_API_KEY:-}"   ]] && pass "GPU_API_KEY set"   || fail "GPU_API_KEY empty — no source fallback exists, LLM calls return \"\" SILENTLY"

echo; echo "── python interpreter ──────────────────────────────────"
PYBIN="$(dirname "$0")/../.venv/bin/python"
if [[ -x "$PYBIN" ]]; then
    PYVER="$("$PYBIN" -c 'import sys;print("%d.%d"%sys.version_info[:2])')"
    # langgraph and the mcp client both require >= 3.10. A venv built with a
    # bare `sudo python3` picks up the system interpreter, which on RHEL 8 is
    # 3.6 — it installs nothing useful and the pip error does not say why.
    "$PYBIN" -c 'import sys;sys.exit(0 if sys.version_info[:2]>=(3,10) else 1)' \
      && pass "venv python $PYVER" \
      || fail "venv python is $PYVER — needs >= 3.10. Rebuild with the interpreter the live service uses: readlink -f <live-venv>/bin/python"
else
    warn "no venv at $PYBIN — skipping interpreter check"
fi

echo; echo "── on-disk assets ──────────────────────────────────────"
[[ -r "${IG_CA_BUNDLE:-/nonexistent}" ]] && pass "CA bundle $IG_CA_BUNDLE" || fail "CA bundle missing — EVERY upstream call fails cert verification"
[[ -r "${VI_TOOL_KB_PATH:-/nonexistent}" ]] && pass "tool KB" || fail "tool KB missing at ${VI_TOOL_KB_PATH:-unset}"
[[ -r "${VI_QUESTION_GUIDE_PATH:-/nonexistent}" ]] && pass "question guide" || warn "question guide missing — app still starts, RAG SILENTLY disabled"

echo; echo "── postgres ────────────────────────────────────────────"
if PGPASSWORD="$IG_DB_PASSWORD" psql -h "$IG_DB_HOST" -p "${IG_DB_PORT:-5432}" -U "$IG_DB_USER" \
     -d "$IG_DB_NAME" -tAc "select 1" >/dev/null 2>&1; then
    pass "connected to $IG_DB_HOST:${IG_DB_PORT:-5432}/$IG_DB_NAME"
    n=$(PGPASSWORD="$IG_DB_PASSWORD" psql -h "$IG_DB_HOST" -U "$IG_DB_USER" -d "$IG_DB_NAME" -tAc \
        "select count(*) from information_schema.tables where table_schema='$IG_DB_SCHEMA' and table_name in ('ig_auth_sessions','ig_auth_login_audit')" 2>/dev/null)
    [[ "$n" == "2" ]] && pass "auth tables present in $IG_DB_SCHEMA" \
        || fail "auth tables missing in $IG_DB_SCHEMA — run sql/setup_ig_auth_tables.sql (these do NOT auto-create)"
else
    fail "cannot connect — check pg_hba.conf covers this host's source address"
fi

echo; echo "── instant graph gateway ───────────────────────────────"
# check-gateway.py is the authority in every case: it mirrors the app's own
# SSL context, SAN pinning and proxy handling, which curl cannot replicate
# (self-signed cert needing VERIFY_X509_PARTIAL_CHAIN, reached by IP while
# the cert's SAN is a DNS name). It honours HTTPS_PROXY exactly as requests
# does, so it covers relayed and direct hosts alike — do NOT infer the mode
# from whether HTTPS_PROXY happens to be set. FALCONPRD reaches the gateway
# directly and is correct with no proxy at all.
echo "     route: ${HTTPS_PROXY:-direct (no proxy)}"
PY="$(dirname "$0")/../.venv/bin/python"
[[ -x "$PY" ]] || PY=python3
if "$PY" "$(dirname "$0")/check-gateway.py" 2>&1 | tail -1 | grep -q '^PASS'; then
    pass "gateway reachable, TLS verified (app's own SSL context)"
else
    fail "gateway unreachable or TLS failed — run deploy/check-gateway.py for the reason"
fi

echo; echo "── gpu inference proxy ─────────────────────────────────"
# Must not go through the relay: it is plain HTTP on .246.
if curl -sS --max-time 20 --noproxy '*' -X POST "$GPU_PROXY_URL" \
      -H 'Content-Type: application/json' -H "X-API-Key: $GPU_API_KEY" \
      -d '{"model":"'"${DEFAULT_MODEL:-mistral}"'","prompt":"SYSTEM:\nreply OK\n\nUSER:\nping\n\nASSISTANT:\n","max_new_tokens":8}' \
      2>/dev/null | grep -q '"text"'; then
    pass "GPU proxy responded with a text field"
else
    fail "GPU proxy $GPU_PROXY_URL not responding — infer() returns \"\" silently, answers degrade with NO error"
fi

echo; echo "── listener ports free ─────────────────────────────────"
for p in "${MCP_PORT:-8056}" "${DASH_PORT:-8060}" "${VI_APP_PORT:-8079}"; do
    ss -lnt 2>/dev/null | grep -q ":$p " && warn "port $p already in use (fine if this env is already running)" || pass "port $p free"
done

echo
[[ $FAIL -eq 0 ]] && echo "PREFLIGHT PASSED" || { echo "PREFLIGHT FAILED — fix the ✗ items before migrating"; exit 1; }
