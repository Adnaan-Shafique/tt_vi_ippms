#!/usr/bin/env bash
# ══════════════════════════════════════════════════════════════════════════
#  promote.sh — promote a tested revision from test to prod
#
#    sudo -u ippms deploy/promote.sh v1.2.0
#
#  Deploys an EXISTING git tag to the prod checkout and restarts prod. It
#  never merges, never builds, never edits .env — it moves prod to a revision
#  you have already run in test. Tag first, test that tag, then promote it.
# ══════════════════════════════════════════════════════════════════════════
set -euo pipefail

TAG="${1:-}"
ROOT=/srv/ippms-assistant
PROD="$ROOT/prod"

if [[ -z "$TAG" ]]; then
    echo "usage: $0 <git-tag>" >&2
    echo "recent tags:" >&2
    git -C "$PROD" tag --sort=-creatordate | head -10 >&2
    exit 1
fi

echo "==> fetching"
git -C "$PROD" fetch --tags --prune origin

git -C "$PROD" rev-parse -q --verify "refs/tags/$TAG" >/dev/null || {
    echo "ERROR: tag '$TAG' does not exist. Tag it and test it first." >&2; exit 1; }

# Refuse to clobber uncommitted edits made directly on the prod box.
if ! git -C "$PROD" diff --quiet || ! git -C "$PROD" diff --cached --quiet; then
    echo "ERROR: prod checkout has uncommitted changes. Investigate before promoting:" >&2
    git -C "$PROD" status --short >&2
    exit 1
fi

CURRENT=$(git -C "$PROD" describe --tags --always)
echo "==> prod: $CURRENT  ->  $TAG"

echo "==> checking out"
git -C "$PROD" checkout -q --detach "$TAG"

echo "==> syncing dependencies"
"$PROD/.venv/bin/pip" install -q -r "$PROD/requirements.txt"

echo "==> byte-compiling (catches a syntax error BEFORE the restart)"
"$PROD/.venv/bin/python" -m py_compile "$PROD"/src/*.py

echo "==> restarting (MCP first — the chat app is its client)"
sudo systemctl restart instant-graph-mcp@prod
sleep 10
sudo systemctl restart talk-to-vi-ippms@prod
sleep 5

systemctl is-active --quiet instant-graph-mcp@prod && systemctl is-active --quiet talk-to-vi-ippms@prod || {
    echo "ERROR: a service failed to come up. Rolling back to $CURRENT" >&2
    git -C "$PROD" checkout -q --detach "$CURRENT"
    sudo systemctl restart instant-graph-mcp@prod
    sleep 10
    sudo systemctl restart talk-to-vi-ippms@prod
    echo "rolled back. check: journalctl -u talk-to-vi-ippms@prod -n 100" >&2
    exit 1
}

echo "==> now on $TAG. Confirm the startup line is CLEAN (no MISSING/disabled):"
journalctl -u talk-to-vi-ippms@prod -n 25 --no-pager | grep -E '\[STARTUP\]' || true
