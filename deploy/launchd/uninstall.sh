#!/usr/bin/env bash
# Remove the launchd LaunchAgent installed by deploy/launchd/install.sh. Data in the vault is
# untouched.
set -euo pipefail
LABEL="${CORTEX_LAUNCHD_LABEL:-com.cortex.local.backend}"
PLIST="$HOME/Library/LaunchAgents/$LABEL.plist"
if [[ -f "$PLIST" ]]; then
  launchctl unload "$PLIST" 2>/dev/null || true
  rm -f "$PLIST"
  echo "removed $PLIST (vault data left in place)"
else
  echo "nothing to remove: $PLIST not found"
fi
