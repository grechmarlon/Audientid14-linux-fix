#!/usr/bin/env bash
# fix-audient-id14.sh — permanent fix for imbalanced audio on the Audient iD14 MkII
# (USB 2708:0008) under PipeWire/WirePlumber.
#
# Root cause: the iD14's hardware 'Speaker Playback Volume' control ignores volume
# writes on the LEFT channel (stuck at max in firmware), and the device declares no
# USB channel positions, so PipeWire auto-generates surround-only profiles that
# drive that broken control — any volume below 100% attenuates only the right
# channel. References: https://bbs.archlinux.org/viewtopic.php?id=289727 and
# https://markwatkinson.uk/knowledge/linux/audient-id14-linux-pipewire-pulseaudio/
#
# What this script does (all user-level, idempotent, survives reboots/updates):
#   1. WirePlumber rule: api.alsa.soft-mixer=true (never touch the hw mixer) and
#      device.profile-set=audient-id14.conf. Written in Lua for WirePlumber 0.4
#      or SPA-JSON conf.d for 0.5+ (auto-detected).
#   2. Custom ACP profile-set: a real Stereo Output profile (stereo -> hw ch 1/2;
#      headphones mirror these). Pro Audio profile remains available.
#   3. Pins the hw mixer at 127/127/127/127 (0 dB — the only setting where L=R).
#   4. Removes poisoned WirePlumber saved state (zeroed/muted volumes, stale
#      surround routes), restarts the stack, sets the stereo sink as default.
#   5. Verifies: stereo profile active, balance 0.00, hw mixer untouched across
#      a volume sweep.
#
# Usage:
#   ./fix-audient-id14.sh           apply + verify
#   ./fix-audient-id14.sh verify    verify only, change nothing
#   ./fix-audient-id14.sh revert    remove the config and restart audio
#   sudo ./fix-audient-id14.sh system   optional hardening (alsactl store,
#                                       /etc profile-set copy, udev rule)
set -euo pipefail

CARD_GLOB='alsa_card.usb-Audient_Audient_iD14*'
PROFILE_SET=audient-id14.conf
LUA_FILE="$HOME/.config/wireplumber/main.lua.d/51-audient-id14.lua"
CONF_FILE="$HOME/.config/wireplumber/wireplumber.conf.d/51-audient-id14.conf"
ACP_FILE="$HOME/.config/alsa-card-profile/mixer/profile-sets/$PROFILE_SET"
STATE_DIR="$HOME/.local/state/wireplumber"

info() { printf '\033[1;34m==>\033[0m %s\n' "$*"; }
ok()   { printf '\033[1;32m OK \033[0m %s\n' "$*"; }
fail() { printf '\033[1;31mFAIL\033[0m %s\n' "$*"; exit 1; }

find_card() {
  # ALSA card id of the iD14, e.g. "iD14" (empty if unplugged)
  sed -n 's/^ *[0-9]* \[\(iD14[^ ]*\) *\].*/\1/p' /proc/asound/cards | head -1
}

wp_minor() { wireplumber --version | sed -n 's/.*libwireplumber \([0-9]*\)\.\([0-9]*\).*/\1\2/p' | head -1; }

write_wireplumber_rule() {
  if [ "$(wp_minor)" -ge 05 ] 2>/dev/null; then
    info "WirePlumber 0.5+: writing $CONF_FILE"
    mkdir -p "$(dirname "$CONF_FILE")"
    cat > "$CONF_FILE" <<EOF
# Audient iD14 MkII: hw volume control ignores writes on the left channel
# (stuck at max) -> software volume only, plus custom stereo profile-set.
monitor.alsa.rules = [
  {
    matches = [
      { device.name = "~$CARD_GLOB" }
    ]
    actions = {
      update-props = {
        api.alsa.soft-mixer = true
        device.profile-set = "$PROFILE_SET"
      }
    }
  }
]
EOF
    rm -f "$LUA_FILE"
  else
    info "WirePlumber 0.4: writing $LUA_FILE"
    mkdir -p "$(dirname "$LUA_FILE")"
    cat > "$LUA_FILE" <<EOF
-- Audient iD14 MkII (2708:0008): the hardware 'Speaker Playback Volume'
-- control ignores writes on the left channel (left stuck at max), so any
-- hardware volume below 100% attenuates only the right channel.
-- Force software-only volume and assign the custom stereo profile-set.
table.insert(alsa_monitor.rules, {
  matches = {
    { { "device.name", "matches", "$CARD_GLOB" } },
  },
  apply_properties = {
    ["api.alsa.soft-mixer"] = true,
    ["device.profile-set"] = "$PROFILE_SET",
  },
})
EOF
  fi
}

write_profile_set() {
  info "Writing ACP profile-set $ACP_FILE"
  mkdir -p "$(dirname "$ACP_FILE")"
  cat > "$ACP_FILE" <<'EOF'
# Audient iD14 MkII (USB 2708:0008). Playback: ch1/2 = main outs (headphones
# mirror these via internal Main Mix), ch3/4 = assignable line outs, ch5/6 =
# loopback send. Device declares no USB channel positions, so without this
# file ACP builds bogus surround-only profiles that drive the broken hw
# volume control (left channel stuck at max).

[General]
auto-profiles = no

[Mapping analog-stereo-mains]
description = Stereo Output 1/2 (Monitors + Headphones)
device-strings = hw:%f,0,0
channel-map = left,right,aux0,aux1,aux2,aux3
direction = output
priority = 100

[Mapping analog-stereo-mic]
description = Mic/Line Inputs 1/2
device-strings = hw:%f,0,0
channel-map = left,right,aux0,aux1,aux2,aux3,aux4,aux5,aux6,aux7,aux8,aux9
direction = input
priority = 100

[Profile output:analog-stereo-mains]
description = Stereo Output
output-mappings = analog-stereo-mains
priority = 100
skip-probe = yes

[Profile output:analog-stereo-mains+input:analog-stereo-mic]
description = Stereo Output + Mic Input 1/2
output-mappings = analog-stereo-mains
input-mappings = analog-stereo-mic
priority = 90
skip-probe = yes
EOF
}

pin_hw_mixer() {
  local card="$1"
  info "Pinning hardware mixer at 0 dB (127 x4) on card $card"
  amixer -q -c "$card" cset name='Speaker Playback Volume' 127,127,127,127
}

clean_state() {
  info "Removing poisoned WirePlumber saved state"
  systemctl --user stop wireplumber
  for f in restore-stream default-profile default-nodes default-routes; do
    [ -f "$STATE_DIR/$f" ] && sed -i '/Audient_iD14/d' "$STATE_DIR/$f"
  done
  systemctl --user start wireplumber
}

restart_stack() {
  info "Restarting PipeWire stack"
  systemctl --user restart pipewire pipewire-pulse wireplumber
}

wait_for_sink() {
  local sink
  for _ in $(seq 1 20); do
    sink=$(pactl list sinks short 2>/dev/null | grep -i audient | awk '{print $2}' | head -1) || true
    [ -n "${sink:-}" ] && { echo "$sink"; return 0; }
    sleep 0.5
  done
  return 1
}

set_default_sink() {
  local sink="$1"
  info "Setting $sink as default (unmuted, 50%)"
  pactl set-default-sink "$sink"
  pactl set-sink-mute "$sink" 0
  pactl set-sink-volume "$sink" 50%
}

verify() {
  local card sink hw bal
  card=$(find_card); [ -n "$card" ] || fail "iD14 not found in /proc/asound/cards — is it plugged in?"

  pactl list cards | grep -q 'output:analog-stereo-mains' \
    && ok "custom Stereo Output profile is present" \
    || fail "Stereo Output profile missing — profile-set not loaded"

  local active
  active=$(pactl list cards | sed -n '/usb-Audient/,$p' | sed -n 's/^\tActive Profile: //p' | head -1)
  case "$active" in
    output:analog-stereo-mains*) ok "active profile: $active" ;;
    pro-audio) ok "active profile: pro-audio (also imbalance-safe; switch to Stereo Output in sound settings if preferred)" ;;
    *) fail "unexpected active profile: $active" ;;
  esac

  sink=$(wait_for_sink) || fail "no Audient sink appeared"
  ok "sink: $sink"

  # Volume sweep must never move the hardware mixer (proves soft-mixer is active)
  local orig_vol
  orig_vol=$(pactl get-sink-volume "$sink" | sed -n 's/.*front-left:[^/]*\/ *\([0-9]*\)%.*/\1/p')
  for v in 30 70 100; do
    pactl set-sink-volume "$sink" "$v%"
    hw=$(amixer -c "$card" cget name='Speaker Playback Volume' | sed -n 's/^ *: values=//p')
    [ "$hw" = "127,127,127,127" ] || fail "hw mixer moved at $v% volume (values=$hw) — soft-mixer not active"
  done
  pactl set-sink-volume "$sink" "${orig_vol:-50}%"
  ok "hw mixer pinned at 127,127,127,127 across 30/70/100% volume sweep"

  bal=$(pactl list sinks | sed -n "/Name: $sink/,/balance/p" | sed -n 's/.*balance \(.*\)/\1/p')
  [ "$bal" = "0.00" ] && ok "software balance: 0.00" || fail "balance is $bal, expected 0.00"

  info "All checks passed. Play audio at a few volumes to confirm by ear."
}

apply() {
  local card
  card=$(find_card); [ -n "$card" ] || fail "iD14 not found in /proc/asound/cards — plug it in first"
  write_wireplumber_rule
  write_profile_set
  pin_hw_mixer "$card"
  clean_state
  restart_stack
  sleep 2
  local sink
  sink=$(wait_for_sink) || fail "no Audient sink appeared after restart"
  set_default_sink "$sink"
  verify
}

revert() {
  info "Removing iD14 config"
  rm -f "$LUA_FILE" "$CONF_FILE" "$ACP_FILE"
  restart_stack
  ok "reverted — the card is back to auto-generated profiles"
}

system_harden() {
  [ "$(id -u)" -eq 0 ] || fail "run this mode with sudo"
  local user_home acp_src
  user_home=$(getent passwd "${SUDO_USER:-$USER}" | cut -d: -f6)
  acp_src="$user_home/.config/alsa-card-profile/mixer/profile-sets/$PROFILE_SET"
  [ -f "$acp_src" ] || fail "$acp_src missing — run the script without sudo first"

  info "Persisting ALSA mixer state (restored on every boot/hotplug)"
  alsactl store

  info "Installing system-wide profile-set and udev rule"
  mkdir -p /etc/alsa-card-profile/mixer/profile-sets
  cp "$acp_src" /etc/alsa-card-profile/mixer/profile-sets/
  cat > /etc/udev/rules.d/91-pipewire-alsa-audient.rules <<EOF
SUBSYSTEM=="sound", ACTION=="change", KERNEL=="card*", SUBSYSTEMS=="usb", ATTRS{idVendor}=="2708", ATTRS{idProduct}=="0008", ENV{ACP_PROFILE_SET}="$PROFILE_SET"
EOF
  udevadm control --reload-rules
  ok "system hardening done"
}

case "${1:-apply}" in
  apply)  apply ;;
  verify) verify ;;
  revert) revert ;;
  system) system_harden ;;
  *) echo "usage: $0 [apply|verify|revert|system]" >&2; exit 2 ;;
esac
