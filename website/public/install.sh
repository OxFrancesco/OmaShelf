#!/bin/bash
# Installs or updates OmaShelf, a file shelf for the Omarchy bar.
#   curl -fsSL https://omashelf.buddytools.org/install.sh | bash
set -euo pipefail

REPO="https://github.com/OxFrancesco/OmaShelf"
ID="omashelf"

say() { printf '%s\n' "$*"; }
fail() { printf 'OmaShelf: %s\n' "$*" >&2; exit 1; }

command -v omarchy >/dev/null || fail "this needs Omarchy. See https://omarchy.org"
command -v omarchy-shell >/dev/null || fail "this needs Omarchy's Quickshell desktop. Update Omarchy first."
omarchy-shell shell ping >/dev/null 2>&1 || fail "the Omarchy shell isn't running."

if [[ -d "$HOME/.config/omarchy/plugins/$ID" ]]; then
  say "Updating OmaShelf..."
  omarchy plugin update "$ID" --yes
else
  say "Installing OmaShelf..."
  omarchy plugin add "$REPO" --enable --yes
  omarchy bar move "$ID" --after omarchy.tray >/dev/null 2>&1 || true
fi

missing=()
command -v python3 >/dev/null || missing+=(python)
command -v wl-copy >/dev/null || missing+=(wl-clipboard)
command -v ffmpegthumbnailer >/dev/null || missing+=(ffmpegthumbnailer)
python3 -c "import gi" >/dev/null 2>&1 || missing+=(python-gobject)
if (( ${#missing[@]} )); then
  say ""
  say "OmaShelf also uses: ${missing[*]}"
  say "Install them with: sudo pacman -S --needed ${missing[*]}"
fi

say ""
say "OmaShelf is in your bar. Drop files on the tray icon, or click it and press Ctrl+V."
