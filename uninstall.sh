#!/usr/bin/env bash
# WEBHOST uninstaller for Linux.
#   curl -fsSL https://brizzad.github.io/webhost-site/uninstall.sh | bash
# Run it as the desktop user that installed it. Stops and removes the user
# service and the program, and asks whether to keep this computer's ID and
# owner account (kept, a later install reuses them) or delete them.
#
# Unattended: RC_PURGE=1 deletes the ID and account, RC_PURGE=0 keeps them.
set -euo pipefail

APP_ID=io.github.brizzad.Webhost
CONFIG_DIR="${XDG_CONFIG_HOME:-$HOME/.config}/webhost"
STATE_DIR="${XDG_STATE_HOME:-$HOME/.local/state}/webhost"
DATA_HOME="${XDG_DATA_HOME:-$HOME/.local/share}"

say() { printf '\033[1;34m==>\033[0m %s\n' "$*"; }
die() { printf '\033[1;31merror:\033[0m %s\n' "$*" >&2; exit 1; }
[ "$(id -u)" -ne 0 ] || die "run this as the desktop user that installed WEBHOST, not root"

if [ -n "${RC_PURGE:-}" ]; then
  purge="$RC_PURGE"
elif [ -f "$CONFIG_DIR/agent.json" ] && [ -r /dev/tty ]; then
  printf "Keep this computer's ID and owner account, so a later install can reuse them? [Y/n] "
  read -r answer < /dev/tty || answer=""
  case "$answer" in [nN]*) purge=1 ;; *) purge=0 ;; esac
else
  purge=0
fi

say "Stopping and removing the background service"
if systemctl --user cat webhost.service >/dev/null 2>&1; then
  systemctl --user disable --now webhost.service < /dev/null || true
fi
rm -f "${XDG_CONFIG_HOME:-$HOME/.config}/systemd/user/webhost.service"
systemctl --user daemon-reload < /dev/null 2>/dev/null || true
# Anything still running from this install (e.g. a foreground `webhost run`).
pkill -u "$(id -u)" -x webhost 2>/dev/null || true

say "Removing the program"
if command -v pacman >/dev/null && pacman -Qq webhost >/dev/null 2>&1; then
  sudo pacman -R --noconfirm webhost < /dev/null
fi
rm -f "$HOME/.local/bin/webhost"
# The desktop entry the agent writes when no package installed one.
entry="$DATA_HOME/applications/$APP_ID.desktop"
if [ -f "$entry" ] && grep -q "webhost" "$entry"; then rm -f "$entry"; fi
# KDE's standing "allow remote control without asking" permission.
if command -v gdbus >/dev/null; then
  gdbus call --session --dest org.freedesktop.impl.portal.PermissionStore \
    --object-path /org/freedesktop/impl/portal/PermissionStore \
    --method org.freedesktop.impl.portal.PermissionStore.DeletePermission kde-authorized remote-desktop "$APP_ID" \
    >/dev/null 2>&1 < /dev/null || true
fi
rm -rf "$STATE_DIR"

if [ "$purge" = 1 ]; then
  rm -rf "$CONFIG_DIR"
  say "Deleted this computer's ID and owner account."
elif [ -d "$CONFIG_DIR" ]; then
  say "Kept this computer's ID and owner account in $CONFIG_DIR (delete that folder to remove them)."
fi
say "WEBHOST is uninstalled."
echo "    Start-at-boot for your user (loginctl enable-linger) was left as it is; turn it off with:"
echo "    loginctl disable-linger \$USER   (only if nothing else of yours needs it)"
