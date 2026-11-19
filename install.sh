#!/usr/bin/env bash
# WEBHOST installer for Linux (Arch gets a pacman package).
#   curl -fsSL https://brizzad.github.io/webhost-site/install.sh | bash
# Run it as your normal desktop user, ideally in a terminal inside your
# graphical session. It uses sudo only to install packages. Running it again
# updates the agent and keeps this computer's ID and owner account.
#
# Unattended (scripts, tests): set RC_USERNAME, RC_PASSWORD and RC_TOTP_SECRET
# (base32) to set up without questions. RC_DOWNLOAD_ONLY=1 only downloads and
# verifies. RC_RELEASE_URL overrides where the release is downloaded from.
set -euo pipefail

REPO="${RC_RELEASE_URL:-https://github.com/brizzad/webhost-site/releases/latest/download}"
SITE="https://brizzad.github.io/webhost-site/"
APP="${SITE}app/"

say() { printf '\033[1;34m==>\033[0m %s\n' "$*"; }
note() { printf '    %s\n' "$*"; }
die() { printf '\033[1;31merror:\033[0m %s\n' "$*" >&2; exit 1; }

[ "$(uname -s)" = Linux ] || die "this installer is for Linux; on Windows use install.ps1"
[ "$(uname -m)" = x86_64 ] || die "only x86_64 builds are available right now"
[ "$(id -u)" -ne 0 ] || die "run this as your normal user, not root (it uses sudo where needed)"
for c in curl sha256sum; do command -v "$c" >/dev/null || die "$c is required"; done

tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT

# Package manager, for the few system packages remote desktop needs.
if command -v pacman >/dev/null; then PM=pacman
elif command -v apt-get >/dev/null; then PM=apt
elif command -v dnf >/dev/null; then PM=dnf
elif command -v zypper >/dev/null; then PM=zypper
else PM=""
fi
installed() {
  case "$PM" in
    pacman) pacman -Qq "$1" >/dev/null 2>&1 ;;
    apt) dpkg-query -W -f='${Status}' "$1" 2>/dev/null | grep -q "ok installed" ;;
    dnf|zypper) rpm -q "$1" >/dev/null 2>&1 ;;
    *) return 1 ;;
  esac
}
# Installs system packages with sudo; explains what to run if that fails.
pkg_install() {
  local missing=() p
  for p in "$@"; do installed "$p" || missing+=("$p"); done
  [ "${#missing[@]}" -gt 0 ] || return 0
  local cmd
  case "$PM" in
    pacman) cmd=(sudo pacman -S --needed --noconfirm "${missing[@]}") ;;
    apt) cmd=(sudo apt-get install -y "${missing[@]}") ;;
    dnf) cmd=(sudo dnf install -y "${missing[@]}") ;;
    zypper) cmd=(sudo zypper --non-interactive install "${missing[@]}") ;;
    *) note "Install these packages with your package manager: ${missing[*]}"; return 1 ;;
  esac
  say "Installing ${missing[*]} (needs your password for sudo)"
  # Not from stdin: that is this script when it is piped into bash.
  if ! "${cmd[@]}" < /dev/null && ! { [ "$PM" = apt ] && sudo apt-get update < /dev/null && "${cmd[@]}" < /dev/null; }; then
    note "That did not work; install them yourself and run this again: ${cmd[*]}"
    return 1
  fi
}

# Downloads a release file and checks it against the release's SHA256SUMS.
fetch() {
  curl -fL --progress-bar -o "$tmp/$1" "$REPO/$1" || die "could not download $1 from $REPO"
  (cd "$tmp" && grep -E "^[0-9a-f]{64}  $1\$" SHA256SUMS > "$1.sum") || die "$1 is not listed in the release checksums"
  (cd "$tmp" && sha256sum -c --quiet "$1.sum") || die "$1 failed its checksum; not installing it"
}
pipewire_pkg() {
  case "$PM" in
    apt) echo libpipewire-0.3-0t64 ;;
    dnf) echo pipewire-libs ;;
    zypper) echo libpipewire-0_3-0 ;;
    *) echo pipewire ;;
  esac
}
# Runs a downloaded webhost once; explains the usual reasons it cannot start.
check_runs() {
  local out
  if out="$("$1" --version 2>&1)"; then echo "    $out"; return 0; fi
  case "$out" in
    *libpipewire*) die "webhost needs PipeWire's library (libpipewire-0.3): install it (e.g. sudo apt install libpipewire-0.3-0t64, or sudo dnf install pipewire-libs) and run this again" ;;
    *GLIBC_*) die "this Linux is too old for the prebuilt webhost (it needs glibc 2.39 or newer, e.g. Ubuntu 24.04, Debian 13, Fedora 40): $out" ;;
    *) die "webhost does not run on this system: $out" ;;
  esac
}

say "Downloading WEBHOST"
curl -fsSL -o "$tmp/SHA256SUMS" "$REPO/SHA256SUMS" ||
  die "could not download the release checksums from $REPO. Check your internet connection; if it works, there may be no release published yet."

if [ "$PM" = pacman ]; then ASSET=webhost-x86_64.pkg.tar.zst; else ASSET=webhost-linux-x86_64; fi
fetch "$ASSET"
# Tests stop here (download and checksum only).
if [ -n "${RC_DOWNLOAD_ONLY:-}" ]; then
  if [ "$ASSET" = webhost-linux-x86_64 ]; then chmod +x "$tmp/$ASSET" && check_runs "$tmp/$ASSET"; fi
  say "downloaded and verified $ASSET"
  exit 0
fi

# Which desktop this is: from this terminal, or (over SSH) from the
# graphical session's environment as systemd knows it.
session_var() {
  local v="${!1:-}"
  [ -n "$v" ] || v="$(systemctl --user show-environment 2>/dev/null | sed -n "s/^$1=//p" | head -n1)"
  printf '%s' "$v"
}
DESKTOP="$(session_var XDG_CURRENT_DESKTOP)"
STYPE="$(session_var XDG_SESSION_TYPE)"
[ -n "$STYPE" ] || { [ -n "$(session_var WAYLAND_DISPLAY)" ] && STYPE=wayland; } || true
[ -n "$STYPE" ] || { [ -n "$(session_var DISPLAY)" ] && STYPE=x11; } || true
# What remote desktop needs here (the same choice the agent makes).
BACKEND=""
case "$STYPE:$DESKTOP" in
  wayland:*KDE*) BACKEND=xdg-desktop-portal-kde ;;
  wayland:*GNOME*) BACKEND=xdg-desktop-portal-gnome ;;
  wayland:*) BACKEND=wayvnc ;;
  x11:*) BACKEND=x11vnc ;;
esac

if [ "$ASSET" = webhost-x86_64.pkg.tar.zst ]; then
  say "Arch Linux: installing the webhost package (needs your password for sudo)"
  sudo pacman -U --needed --noconfirm "$tmp/webhost-x86_64.pkg.tar.zst" < /dev/null
  WEBHOST=/usr/bin/webhost
else
  say "Installing webhost to ~/.local/bin"
  if ! out="$(chmod +x "$tmp/$ASSET" && "$tmp/$ASSET" --version 2>&1)" && [[ "$out" == *libpipewire* ]]; then
    pkg_install "$(pipewire_pkg)" || true
  fi
  mkdir -p "$HOME/.local/bin"
  install -m 755 "$tmp/webhost-linux-x86_64" "$HOME/.local/bin/webhost"
  WEBHOST="$HOME/.local/bin/webhost"
fi
check_runs "$WEBHOST"
if [ -n "$BACKEND" ]; then
  pkg_install "$BACKEND" || note "Remote desktop needs $BACKEND on this desktop; the terminal works without it."
fi

say "Setting up this computer"
# An existing setup is kept (webhost setup --force replaces the account).
if [ -n "${RC_USERNAME:-}" ] && [ -n "${RC_PASSWORD:-}" ] && [ -n "${RC_TOTP_SECRET:-}" ]; then
  "$WEBHOST" setup --username "$RC_USERNAME" --password-env RC_PASSWORD --totp-secret "$RC_TOTP_SECRET"
else
  # The script itself may be piped into bash, so answers come from the terminal.
  [ -r /dev/tty ] || die "setup needs a terminal to ask for your password (or set RC_USERNAME, RC_PASSWORD and RC_TOTP_SECRET)"
  "$WEBHOST" setup < /dev/tty
fi

say "Starting WEBHOST now and whenever this computer starts"
"$WEBHOST" service install < /dev/null
if loginctl enable-linger "$USER" 2>/dev/null; then
  note "It starts at boot, before you sign in. The terminal works from then on; the"
  note "remote desktop works while you are signed in to your desktop."
else
  note "It starts when you sign in (could not enable start-at-boot: loginctl enable-linger $USER)."
fi

for _ in 1 2 3 4 5; do
  status="$("$WEBHOST" status 2>&1 < /dev/null || true)"
  grep -q '^running: *yes' <<<"$status" && break
  sleep 1
done
echo
if grep -q '^running: *yes' <<<"$status"; then
  printf '\033[1;32mWEBHOST is installed and running.\033[0m\n\n'
else
  printf '\033[1;33mWEBHOST is installed but not running; see: journalctl --user -u webhost\033[0m\n\n'
fi
printf '  Computer ID:  %s\n' "$(sed -n 's/^id: *\([0-9 ]*[0-9]\).*/\1/p' <<<"$status")"
printf '  Username:     %s\n' "$(sed -n 's/^owner: *//p' <<<"$status")"
printf '  Connect from: %s\n\n' "$APP"
desk="$(sed -n 's/^desktop: *//p' <<<"$status")"
case "$desk" in
  available*) printf '  Remote desktop: %s\n' "$desk" ;;
  *) printf '  Remote desktop: \033[1;33m%s\033[0m\n' "${desk:-unknown}" ;;
esac
printf '  Sign in there with this username, your password and a code from your authenticator app.\n'
if [ "$WEBHOST" = "$HOME/.local/bin/webhost" ]; then
  printf '  Updates:      automatic (signed; installed when nobody is connected).\n'
else
  printf '  Updates:      with your system updates (pacman -Syu).\n'
fi
printf '  Check it any time:  webhost status\n'
printf '  Logs:               journalctl --user -u webhost -f\n'
printf '  Uninstall:          curl -fsSL %suninstall.sh | bash\n' "$SITE"
if [ "$WEBHOST" = "$HOME/.local/bin/webhost" ]; then
  case ":$PATH:" in *":$HOME/.local/bin:"*) ;; *) note "(add ~/.local/bin to your PATH to run webhost directly)" ;; esac
fi
