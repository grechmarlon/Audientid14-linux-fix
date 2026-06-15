#!/usr/bin/env bash
# setup-rocksmith.sh — first-time, from-scratch setup of Rocksmith 2014 + Audient
# iD14 + wineASIO low-latency guitar under Proton. Fetches what it can from
# upstream and writes our own config inline, so it works from a fresh git clone
# (no ./rocksmith/ bundle needed). Run from the audiofix folder.
#
#   ./setup-rocksmith.sh
#
# vs restore-rocksmith.sh: restore replays an exact ./rocksmith/ snapshot; this
# fetches current upstream releases. Both end by calling fix-audient-id14.sh and
# both produce the same reboot-safe result.
#
# PREREQUISITES:
#   1. Install Steam, sign in, and install Rocksmith 2014 (appid 221680).
#   2. Launch the game once (then quit) so its Proton prefix + Rocksmith.ini exist.
#   3. wineASIO has no clean prebuilt download. Provide it ONE of these ways:
#        - WINEASIO_DEB=/path/to/wineasio_*.deb   (KXStudio .deb — recommended)
#        - WINEASIO_DIR=/dir/with/the/4/wineasio/dlls
#        - or have a ./rocksmith/ bundle (from backup-rocksmith.sh) present
#      If none is found the script does everything else and tells you what's left.
set -uo pipefail

KIT="$(cd "$(dirname "$0")" && pwd)"
BUNDLE="$KIT/rocksmith"

APPID=221680
GE_NAME="GE-Proton9-27"
GE_URL="https://github.com/GloriousEggroll/proton-ge-custom/releases/download/$GE_NAME/$GE_NAME.tar.gz"
RS_ASIO_VER="0.7.4"
RS_ASIO_URL="https://github.com/mdias/rs_asio/releases/download/v$RS_ASIO_VER/release-$RS_ASIO_VER.zip"
WINEASIO_CLSID="{48D0C522-BFCC-45CC-8B84-17F25F33E6E8}"
COMPAT_DIR="$HOME/.local/share/Steam/compatibilitytools.d"
GE_DIR="$COMPAT_DIR/$GE_NAME"
BIN="$HOME/.local/bin"

info() { printf '\033[1;34m==>\033[0m %s\n' "$*"; }
ok()   { printf '\033[1;32m OK \033[0m %s\n' "$*"; }
warn() { printf '\033[1;33m !! \033[0m %s\n' "$*"; }

# --- locate the Steam library holding Rocksmith (override: STEAM_LIBRARY=/path) -
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
[ -n "$LIB" ] || { warn "Rocksmith ($APPID) not found — install it via Steam (and set STEAM_LIBRARY= if on another drive), then re-run."; exit 1; }
GAME_ROOT="$LIB/steamapps/common/Rocksmith2014"
PFX="$LIB/steamapps/compatdata/$APPID/pfx"
ok "Game: $GAME_ROOT"

# --- 1) packages --------------------------------------------------------------
install_packages() {
  info "Installing PipeWire-JACK (64+32-bit) + pipewire-audio + tools"
  sudo dpkg --add-architecture i386
  sudo apt-get update -y
  sudo apt-get install -y pipewire-audio pipewire-jack pipewire-jack:i386 curl unzip \
    || warn "apt step failed — ensure pipewire-jack / pipewire-jack:i386 / unzip / curl are installed"
}

# --- 2) GE-Proton -------------------------------------------------------------
install_ge() {
  mkdir -p "$COMPAT_DIR"
  if [ -d "$GE_DIR" ]; then ok "GE-Proton already present"; return 0; fi
  info "Downloading $GE_NAME"
  curl -fL "$GE_URL" -o "/tmp/$GE_NAME.tar.gz" && tar -xzf "/tmp/$GE_NAME.tar.gz" -C "$COMPAT_DIR" \
    && ok "GE-Proton installed" \
    || { warn "GE-Proton download failed — install $GE_NAME into $COMPAT_DIR manually"; return 1; }
}

# --- 3) wineASIO DLLs into GE-Proton (bundle / .deb / dir / system) ------------
install_wineasio() {
  local d32w="$GE_DIR/files/lib/wine/i386-windows"   d32u="$GE_DIR/files/lib/wine/i386-unix"
  local d64w="$GE_DIR/files/lib64/wine/x86_64-windows" d64u="$GE_DIR/files/lib64/wine/x86_64-unix"
  local tmp; tmp="$(mktemp -d)"; local srcdir=""

  if [ -d "$BUNDLE/wineasio" ]; then
    info "wineASIO: using ./rocksmith bundle"
    cp -av "$BUNDLE/wineasio/lib/wine/i386-windows/wineasio32.dll"     "$d32w/"
    cp -av "$BUNDLE/wineasio/lib/wine/i386-unix/wineasio32.dll.so"     "$d32u/"
    cp -av "$BUNDLE/wineasio/lib64/wine/x86_64-windows/wineasio64.dll" "$d64w/"
    cp -av "$BUNDLE/wineasio/lib64/wine/x86_64-unix/wineasio64.dll.so" "$d64u/"
    ok "wineASIO DLLs in place"; rm -rf "$tmp"; return 0
  fi

  if [ -n "${WINEASIO_DEB:-}" ] && [ -f "$WINEASIO_DEB" ]; then
    info "wineASIO: extracting $WINEASIO_DEB"
    dpkg-deb -x "$WINEASIO_DEB" "$tmp"; srcdir="$tmp"
  elif [ -n "${WINEASIO_DIR:-}" ] && [ -d "$WINEASIO_DIR" ]; then
    srcdir="$WINEASIO_DIR"
  elif find /usr/lib -name 'wineasio64.dll*' 2>/dev/null | grep -q .; then
    info "wineASIO: copying from system install"; srcdir="/usr"
  else
    warn "wineASIO not found. Get the KXStudio wineASIO .deb and re-run with WINEASIO_DEB=/path/to/it,"
    warn "or WINEASIO_DIR=/dir/with/the/dlls, or run backup-rocksmith.sh on a working machine."
    rm -rf "$tmp"; return 1
  fi

  local f n
  for n in wineasio32.dll wineasio32.dll.so wineasio64.dll wineasio64.dll.so; do
    f="$(find "$srcdir" -name "$n" 2>/dev/null | head -1)"
    [ -n "$f" ] || { warn "missing $n in wineASIO source"; rm -rf "$tmp"; return 1; }
    case "$n" in
      wineasio32.dll)    cp -av "$f" "$d32w/";;
      wineasio32.dll.so) cp -av "$f" "$d32u/";;
      wineasio64.dll)    cp -av "$f" "$d64w/";;
      wineasio64.dll.so) cp -av "$f" "$d64u/";;
    esac
  done
  rm -rf "$tmp"; ok "wineASIO DLLs in place"
}

# --- 4) RS_ASIO (download) ----------------------------------------------------
install_rs_asio() {
  [ -d "$GAME_ROOT" ] || { warn "game root missing — install Rocksmith first"; return 1; }
  info "Downloading RS_ASIO v$RS_ASIO_VER"
  local tmp; tmp="$(mktemp -d)"
  if curl -fL "$RS_ASIO_URL" -o "$tmp/rs.zip" && unzip -oq "$tmp/rs.zip" -d "$tmp"; then
    cp -av "$(find "$tmp" -name avrt.dll | head -1)"    "$GAME_ROOT/"
    cp -av "$(find "$tmp" -name RS_ASIO.dll | head -1)" "$GAME_ROOT/"
    ok "RS_ASIO avrt.dll + RS_ASIO.dll -> game root"
  else
    warn "RS_ASIO download failed — get it from $RS_ASIO_URL and drop avrt.dll + RS_ASIO.dll in the game root"
  fi
  rm -rf "$tmp"
}

# --- 5) helper scripts (our own; written inline) ------------------------------
write_helpers() {
  mkdir -p "$BIN"
  cat > "$BIN/rs-asio-link.sh" <<'SH'
#!/usr/bin/env bash
# rs-asio-link.sh — keep wineASIO (Rocksmith2014) JACK ports linked to the iD14.
# wineASIO autoconnect is off (HDMI enumerates first), so link explicitly. Polls
# every 1s so menu<->song re-inits get re-linked. pw-link is idempotent.
set -u
CLIENT="${1:-Rocksmith2014}"
link() { pw-link "$1" "$2" 2>/dev/null || true; }
while :; do
  if pw-link -o 2>/dev/null | grep -q "^${CLIENT}:out_1$"; then
    SINK=$(pw-link -i 2>/dev/null | grep -m1 -oE 'alsa_output\.usb-Audient[^:]*:playback_FL' | sed 's/:playback_FL//')
    SRC=$( pw-link -o 2>/dev/null | grep -m1 -oE 'alsa_input\.usb-Audient[^:]*:capture_FL'  | sed 's/:capture_FL//')
    if [ -n "$SINK" ]; then
      link "${CLIENT}:out_1" "${SINK}:playback_FL"
      link "${CLIENT}:out_2" "${SINK}:playback_FR"
    fi
    if [ -n "$SRC" ]; then
      link "${SRC}:capture_FL" "${CLIENT}:in_1"
      link "${SRC}:capture_FR" "${CLIENT}:in_2"
    fi
  fi
  sleep 1
done
SH
  cat > "$BIN/rs-launch.sh" <<'SH'
#!/usr/bin/env bash
# rs-launch.sh — Steam launch wrapper: run the iD14 relinker alongside the game.
linker="$HOME/.local/bin/rs-asio-link.sh"
"$linker" Rocksmith2014 &
linker_pid=$!
"$@"
ret=$?
kill "$linker_pid" 2>/dev/null
exit "$ret"
SH
  chmod +x "$BIN/rs-asio-link.sh" "$BIN/rs-launch.sh"
  ok "helper scripts -> $BIN"
}

# --- 6) RS_ASIO.ini (ASIO input + WASAPI output) ------------------------------
write_rs_asio_ini() {
  [ -d "$GAME_ROOT" ] || return 1
  cat > "$GAME_ROOT/RS_ASIO.ini" <<'INI'
# RS_ASIO — ASIO (wineASIO) low-latency guitar input + WASAPI output.
[Config]
EnableWasapiOutputs=1
EnableWasapiInputs=0
EnableAsio=1

[Asio]
BufferSizeMode=driver
CustomBufferSize=

[Asio.Output]
Driver=
BaseChannel=0
AltBaseChannel=
EnableSoftwareEndpointVolumeControl=1
EnableSoftwareMasterVolumeControl=1
SoftwareMasterVolumePercent=100
EnableRefCountHack=

[Asio.Input.0]
Driver=WineASIO
Channel=0
EnableSoftwareEndpointVolumeControl=1
EnableSoftwareMasterVolumeControl=1
SoftwareMasterVolumePercent=100
EnableRefCountHack=

[Asio.Input.1]
Driver=
Channel=1

[Asio.Input.Mic]
Driver=
Channel=1
INI
  ok "RS_ASIO.ini written"
}

# --- 7) Rocksmith.ini audio tweaks --------------------------------------------
patch_rocksmith_ini() {
  local f="$GAME_ROOT/Rocksmith.ini"
  [ -f "$f" ] || { warn "Rocksmith.ini not found — launch the game once, then re-run this step"; return 0; }
  set_key() { grep -q "^$1=" "$f" && sed -i "s/^$1=.*/$1=$2/" "$f" || sed -i "0,/^\[Audio\]/s//[Audio]\n$1=$2/" "$f"; }
  set_key EnableMicrophone 0       # stop the 3ms WASAPI mic open
  set_key ExclusiveMode 1
  set_key Win32UltraLowLatencyMode 0   # fixes the logo/startup crash
  set_key LatencyBuffer 8
  ok "Rocksmith.ini patched (EnableMicrophone=0, ExclusiveMode=1, Win32UltraLowLatencyMode=0)"
}

# --- 8) wineASIO registration in the prefix -----------------------------------
register_wineasio() {
  [ -d "$PFX" ] || { warn "prefix missing — launch the game once, then re-run this step"; return 0; }
  if grep -qi 'ASIO\\\\WineASIO' "$PFX/system.reg" 2>/dev/null; then ok "wineASIO already registered"; return 0; fi
  local reg; reg="$(mktemp)"
  cat > "$reg" <<EOF
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
  WINEPREFIX="$PFX" WINEDEBUG=-all "$GE_DIR/files/bin/wine" regedit /S "$reg" 2>/dev/null \
    && ok "wineASIO registered in the prefix" \
    || warn "auto-register failed — run:  protontricks $APPID regedit $reg  (or import via winecfg)"
}

# --- 9) audio fix (imbalance + capture pin) + reboot persistence --------------
run_audiofix() { info "Running fix-audient-id14.sh apply --wineasio"; ( cd "$KIT" && ./fix-audient-id14.sh apply --wineasio ) || warn "audiofix reported an issue"; }
harden()       { info "Persisting hw mixer across reboots (sudo)";    ( cd "$KIT" && sudo ./fix-audient-id14.sh system )   || warn "run 'sudo ./fix-audient-id14.sh system' later"; }

install_packages
install_ge
install_wineasio
install_rs_asio
write_helpers
write_rs_asio_ini
patch_rocksmith_ini
register_wineasio
run_audiofix
harden

echo
ok "Setup done."
echo "OPTIONAL (CDLC/custom songs): drop a d3dx9_42.dll into the game root"
echo "  ($GAME_ROOT). It's already in the WINEDLLOVERRIDES below; without it,"
echo "  only on-disc/official songs work."
echo
echo "Paste into Steam > Rocksmith 2014 > Properties > Launch Options (EXACTLY):"
echo
echo "WINEASIO_CONNECT_TO_HARDWARE=0 LD_PRELOAD=/usr/lib/i386-linux-gnu/pipewire-0.3/jack/libjack.so.0 PIPEWIRE_LATENCY=512/48000 WINEDLLOVERRIDES=\"avrt=n,b;d3dx9_42=n,b\" $HOME/.local/bin/rs-launch.sh %command%"
echo
echo "Then launch, open the tuner to confirm input, and play. Reboot-safe — no re-runs."
