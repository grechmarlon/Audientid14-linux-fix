#!/usr/bin/env bash
# backup-rocksmith.sh — snapshot the Rocksmith 2014 + wineASIO-SPECIFIC bits into
# ./rocksmith/ so restore-rocksmith.sh can rebuild after an OS reformat.
#
# The iD14 AUDIO config is NOT backed up here — it lives in fix-audient-id14.sh
# (run by restore-rocksmith.sh). This only captures the Rocksmith/wineASIO layer.
#
# Re-run any time you tweak RS_ASIO.ini / Rocksmith.ini / the helper scripts.
set -u

KIT="$(cd "$(dirname "$0")" && pwd)"
B="$KIT/rocksmith"

APPID=221680
GE_NAME="GE-Proton9-27"
GE_DIR="$HOME/.local/share/Steam/compatibilitytools.d/$GE_NAME"
BIN="$HOME/.local/bin"
WINEASIO_CLSID="{48D0C522-BFCC-45CC-8B84-17F25F33E6E8}"

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
[ -n "$LIB" ] || { echo "Rocksmith ($APPID) library not found — set STEAM_LIBRARY=/path/to/SteamLibrary and re-run."; exit 1; }
GAME_ROOT="$LIB/steamapps/common/Rocksmith2014"
PFX="$LIB/steamapps/compatdata/$APPID/pfx"

copy() { local src="$1" dst="$2"
  if [ -e "$src" ]; then mkdir -p "$dst"; cp -a "$src" "$dst/" && echo " OK  $(basename "$src")"
  else echo " !!  MISSING: $src"; fi; }

echo "### Snapshotting Rocksmith layer to $B"
rm -rf "$B"; mkdir -p "$B"

# wineASIO DLLs (small; they live inside GE-Proton which is NOT on a surviving drive)
copy "$GE_DIR/files/lib/wine/i386-windows/wineasio32.dll"     "$B/wineasio/lib/wine/i386-windows"
copy "$GE_DIR/files/lib/wine/i386-unix/wineasio32.dll.so"     "$B/wineasio/lib/wine/i386-unix"
copy "$GE_DIR/files/lib64/wine/x86_64-windows/wineasio64.dll" "$B/wineasio/lib64/wine/x86_64-windows"
copy "$GE_DIR/files/lib64/wine/x86_64-unix/wineasio64.dll.so" "$B/wineasio/lib64/wine/x86_64-unix"

# game-root drop-ins + the two tuned .ini files
for f in avrt.dll RS_ASIO.dll RS_ASIO.ini d3dx9_42.dll Rocksmith.ini; do
  copy "$GAME_ROOT/$f" "$B/game-root"
done

# helper scripts
copy "$BIN/rs-launch.sh"    "$B/home-bin"
copy "$BIN/rs-asio-link.sh" "$B/home-bin"

# wineASIO prefix registration (.reg)
cat > "$B/wineasio.reg" <<EOF
REGEDIT4

[HKEY_LOCAL_MACHINE\\Software\\ASIO\\WineASIO]
"CLSID"="$WINEASIO_CLSID"
"Description"="WineASIO Driver"

[HKEY_LOCAL_MACHINE\\Software\\Wow6432Node\\ASIO\\WineASIO]
"CLSID"="$WINEASIO_CLSID"
"Description"="WineASIO Driver"

[HKEY_LOCAL_MACHINE\\Software\\Classes\\CLSID\\$WINEASIO_CLSID]
@="WineASIO Object"

[HKEY_LOCAL_MACHINE\\Software\\Classes\\CLSID\\$WINEASIO_CLSID\\InProcServer32]
@="wineasio64.dll"
"ThreadingModel"="Apartment"

[HKEY_LOCAL_MACHINE\\Software\\Classes\\Wow6432Node\\CLSID\\$WINEASIO_CLSID]
@="WineASIO Object"

[HKEY_LOCAL_MACHINE\\Software\\Classes\\Wow6432Node\\CLSID\\$WINEASIO_CLSID\\InProcServer32]
@="wineasio32.dll"
"ThreadingModel"="Apartment"
EOF
echo " OK  wineasio.reg"

# Steam launch options (paste EXACTLY — no "..." or the cable shows "unplugged")
{
  printf '%s\n\n' "WINEASIO_CONNECT_TO_HARDWARE=0 LD_PRELOAD=/usr/lib/i386-linux-gnu/pipewire-0.3/jack/libjack.so.0 PIPEWIRE_LATENCY=512/48000 WINEDLLOVERRIDES=\"avrt=n,b;d3dx9_42=n,b\" $HOME/.local/bin/rs-launch.sh %command%"
  echo "# LD_PRELOAD path is Ubuntu/Debian i386-multiarch; adjust for other distros."
  echo "# Crash debugging: prepend  PROTON_LOG=1  (writes \$HOME/steam-$APPID.log)"
} > "$B/launch-options.txt"
echo " OK  launch-options.txt"

# reference manifest
{
  echo "GE-Proton expected: $GE_NAME"
  echo "Game root:  $GAME_ROOT"
  echo "Prefix:     $PFX"
  echo "apt needs:  pipewire-audio pipewire-jack pipewire-jack:i386"
} > "$B/MANIFEST.txt"
echo " OK  MANIFEST.txt"
echo "### Done -> $B"
