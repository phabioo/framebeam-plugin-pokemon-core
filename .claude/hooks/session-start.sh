#!/usr/bin/env bash
# SessionStart hook (synchronous): prepares cloud sessions. Quiet, idempotent, never blocks.
# Only active in remote environments. Installs lua5.4 via apt if missing (nothing else).
[ "${CLAUDE_CODE_REMOTE:-}" = "true" ] || exit 0
set -uo pipefail

warn() { echo "session-start: $1" >&2; }

if ! command -v lua5.4 >/dev/null 2>&1; then
  if command -v apt-get >/dev/null; then
    SUDO=""; [ "$(id -u)" = 0 ] || SUDO="sudo"
    log="$(mktemp)"
    if ! bash -c "$SUDO apt-get update -qq && DEBIAN_FRONTEND=noninteractive $SUDO apt-get install -y -qq lua5.4" >"$log" 2>&1; then
      warn "lua5.4 install failed"; tail -n 10 "$log" >&2
    fi
    rm -f "$log"
  else
    warn "apt-get missing (lua5.4 not installed)"
  fi
fi
exit 0
