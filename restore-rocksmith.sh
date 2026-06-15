#!/usr/bin/env bash
# restore-rocksmith.sh — rebuild the full Rocksmith 2014 + Audient iD14 + wineASIO
# low-latency setup after an OS-drive reformat. Run from the audiofix folder.
#
#   ./restore-rocksmith.sh
#
# It restores the Rocksmith/wineASIO layer from ./rocksmith/ (made by
# backup-rocksmith.sh) and runs ./fix-audient-id14.sh apply --wineasio for the
# audio (imbalance fix + capture-clock pin). All steps are idempotent and
# reboot-safe — once this finishes you never run it again unless you reformat.
#
# PREREQUISITES (do these first — they can't be scripted reliably):
#   1. Install Steam and sign in.
#   2. If your game library is on a separate drive that survived the reformat,
#      add it back in Steam > Settings > Storage > Add Drive. Rocksmith + its
#      prefix live there, so the game then shows as already installed. (If the
#      library isn't auto-found, run this script with STEAM_LIBRARY=/path/to/lib.)
#   3. Leave GE-Proton missing — this script installs it (or run the game once
#      so the prefix path exists).
set -uo pipefail

KIT="$(cd "$(dirname "$0")" && pwd)"
B="$KIT/rocksmith"

APPID=221680
GE_NAME="GE-Proton9-27"
COMPAT_DIR="$HOME/.local/share/Steam/compatibilitytools.d"
GE_DIR="$COMPAT_DIR/$GE_NAME"
BIN="$HOME/.local/bin"
GE_URL="https://github.com/GloriousEggroll/proton-ge-custom/releases/download/$GE_NAME/$GE_NAME.tar.gz"

# Locate the Steam library that holds Rocksmith (override: STEAM_LIBRARY=/path).
detect_library() {
  [ -n "${STEAM_LIBRARY:-}" ] && { echo "$STEAM_LIBRARY"; return 0; }
  local vdf p
  for vdf in "$HOME/.local/share/Steam/steamapps/libraryfolders.vdf" \
             "$HOME/.steam/steam/steamapps/libraryfolders.vdf" \
             "$HOME/.steam/root/steamapps/libraryfolders.vdf"; do
    [ -f "$vdf" ] || continue
    while IFS= read -r p; do
      [ -f "$p/steamapps/appmanifest_$APPID.acf" ] && { echo "$p"; return 0; }
    done < <(grep -oP '"path"\s*"\K[^"]+' "$vdf" 2>/dev/null)
  done
  return 1
}
LIB="$(detect_library || true)"
if [ -n "$LIB" ]; then
  GAME_ROOT="$LIB/steamapps/common/Rocksmith2014"
  PFX="$LIB/steamapps/compatdata/$APPID/pfx"
else
  GAME_ROOT=""; PFX=""   # game not installed yet; steps below will warn
fi

info() { printf '\033[1;34m==>\033[0m %s\n' "$*"; }
ok()   { printf '\033[1;32m OK \033[0m %s\n' "$*"; }
warn() { printf '\033[1;33m !! \033[0m %s\n' "$*"; }

[ -d "$B" ] || { echo "missing $B — run ./backup-rocksmith.sh on the working machine first"; exit 1; }

# 1) system packages -----------------------------------------------------------
install_packages() {
  info "Installing PipeWire-JACK (64+32-bit) + pipewire-audio"
  sudo dpkg --add-architecture i386
  sudo apt-get update -y
  sudo apt-get install -y pipewire-audio pipewire-jack pipewire-jack:i386 \
    || warn "apt install failed — install pipewire-jack / pipewire-jack:i386 manually"
}

# 2) GE-Proton (download if absent) + inject the bundled wineASIO DLLs ----------
restore_ge_and_wineasio() {
  mkdir -p "$COMPAT_DIR"
  if [ ! -d "$GE_DIR" ]; then
    if [ -f "$B/ge-proton/$GE_NAME.tar.gz" ]; then
      info "Extracting bundled $GE_NAME"
      tar -xzf "$B/ge-proton/$GE_NAME.tar.gz" -C "$COMPAT_DIR"
    else
      info "Downloading $GE_NAME from GitHub"
      curl -fL "$GE_URL" -o "/tmp/$GE_NAME.tar.gz" \
        && tar -xzf "/tmp/$GE_NAME.tar.gz" -C "$COMPAT_DIR" \
        || { warn "GE-Proton download failed — install $GE_NAME into $COMPAT_DIR manually, then re-run"; return 1; }
    fi
  fi
  ok "GE-Proton present: $GE_DIR"

  info "Injecting wineASIO DLLs into GE-Proton"
  cp -av "$B/wineasio/lib/wine/i386-windows/wineasio32.dll"     "$GE_DIR/files/lib/wine/i386-windows/"
  cp -av "$B/wineasio/lib/wine/i386-unix/wineasio32.dll.so"     "$GE_DIR/files/lib/wine/i386-unix/"
  cp -av "$B/wineasio/lib64/wine/x86_64-windows/wineasio64.dll" "$GE_DIR/files/lib64/wine/x86_64-windows/"
  cp -av "$B/wineasio/lib64/wine/x86_64-unix/wineasio64.dll.so" "$GE_DIR/files/lib64/wine/x86_64-unix/"
  ok "wineASIO DLLs in place"
}

# 3) helper scripts ------------------------------------------------------------
restore_helpers() {
  mkdir -p "$BIN"
  cp -av "$B/home-bin/rs-launch.sh" "$B/home-bin/rs-asio-link.sh" "$BIN/"
  chmod +x "$BIN/rs-launch.sh" "$BIN/rs-asio-link.sh"
  ok "helper scripts -> $BIN"
}

# 4) game-root drop-ins (survive on the library drive; re-placed for reinstalls) -
restore_gameroot() {
  if [ -d "$GAME_ROOT" ]; then
    cp -av "$B"/game-root/* "$GAME_ROOT/"
    ok "RS_ASIO + d3dx9 + tuned .ini files -> game root"
  else
    warn "$GAME_ROOT not found — install Rocksmith via Steam, then re-run (or copy $B/game-root/* yourself)"
  fi
}

# 5) wineASIO registration in the prefix (only if not already there) -----------
register_wineasio() {
  if [ ! -d "$PFX" ]; then
    warn "prefix $PFX missing — launch the game once to create it, then re-run this step"
    return 0
  fi
  if grep -qi 'ASIO\\\\WineASIO' "$PFX/system.reg" 2>/dev/null; then
    ok "wineASIO already registered in the prefix"
    return 0
  fi
  info "Importing wineASIO registration into the prefix"
  WINEPREFIX="$PFX" WINEDEBUG=-all "$GE_DIR/files/bin/wine" regedit /S "$B/wineasio.reg" 2>/dev/null \
    && ok "wineASIO registered" \
    || warn "auto-register failed — run:  protontricks 221680 regedit $B/wineasio.reg  (or import it via winecfg)"
}

# 6) audio: imbalance fix + capture-clock pin (the standalone audiofix) ---------
run_audiofix() {
  info "Running fix-audient-id14.sh apply --wineasio"
  ( cd "$KIT" && ./fix-audient-id14.sh apply --wineasio ) || warn "audiofix reported an issue — check its output above"
}

# 7) reboot-safe hw-mixer persistence (sudo; one time) -------------------------
harden() {
  info "Persisting hw mixer + profile across reboots (needs sudo)"
  ( cd "$KIT" && sudo ./fix-audient-id14.sh system ) || warn "system hardening skipped/failed — run 'sudo ./fix-audient-id14.sh system' later"
}

install_packages
restore_ge_and_wineasio
restore_helpers
restore_gameroot
register_wineasio
run_audiofix
harden

echo
ok "Restore complete."
echo "Final step — paste this into Steam > Rocksmith 2014 > Properties > Launch Options"
echo "(EXACTLY, no \"...\" placeholders or the cable will read 'unplugged'):"
echo
sed -n '1p' "$B/launch-options.txt"
echo
echo "Then launch, go to the tuner to confirm input, and play. This setup is"
echo "reboot-safe; you will not need to run this again unless you reformat."
