#!/bin/bash
# Stops the app, removes it and its login item.
set -euo pipefail
LABEL="io.github.alkbt-id.sysload"
launchctl bootout "gui/$(id -u)/$LABEL" 2>/dev/null || true
pkill -x SysLoad 2>/dev/null || true
rm -f "$HOME/Library/LaunchAgents/$LABEL.plist"
rm -rf "$HOME/Applications/SysLoad.app"
echo "Removed."
