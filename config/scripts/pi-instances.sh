#!/usr/bin/env bash
# Dedicated read-only Pi overview. No model requests, tools or other extensions.
set -euo pipefail
if (( $# )); then
  printf 'Usage: pi-instances (no arguments; use /instances inside Pi for an embedded view)\n' >&2
  exit 2
fi
exec pi --no-extensions \
  --extension "$HOME/.pi/agent/extensions/instances" \
  --no-tools --no-mcp --no-skills --no-prompt-templates --no-context-files \
  --no-approve --no-session --offline --instances
