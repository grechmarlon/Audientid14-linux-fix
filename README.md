# Audient iD14 MkII — permanent fix for imbalanced audio on Linux

Fixed: 2026-06-11 · Ubuntu 24.04.4 · PipeWire 1.0.5 · WirePlumber 0.4.17

**Everything below is packaged in [fix-audient-id14.sh](fix-audient-id14.sh):**

```bash
./fix-audient-id14.sh                  # imbalance fix + verify (idempotent)
./fix-audient-id14.sh apply --wineasio # also pin capture@512 for wineASIO/Rocksmith
./fix-audient-id14.sh verify           # check only, change nothing
./fix-audient-id14.sh revert           # remove the config, back to stock behavior
sudo ./fix-audient-id14.sh system      # optional hardening (see below)
```

The script auto-detects WirePlumber 0.4 (Lua) vs 0.5+ (conf.d) — safe to re-run
after a distro upgrade or on another machine with the same interface.

## The bug

Two stacked problems, both device-specific (USB ID 2708:0008):

1. **The real cause of the L/R imbalance:** the iD14's hardware `Speaker Playback
   Volume` control ignores volume writes on the **left** channel (stuck at max in
   firmware). Whenever PipeWire used hardware volume, lowering the volume only
   attenuated the right channel — imbalanced below 100%, equal at exactly 100%.
   (Confirmed: Arch BBS thread 289727, markwatkinson.uk iD14 guide. No kernel fix
   exists for 2708:0008.)
2. The device's USB descriptor declares no channel positions, so the kernel invents
   a surround layout (`FL FR FC LFE RL RR`) and PipeWire generated **only surround
   profiles** (2.1/4.1/5.1) — no stereo profile — which is what put the hardware
   volume in play and mangled stereo routing.

## The fix (all user-level, survives reboots and package updates)

| File | Purpose |
|---|---|
| `~/.config/wireplumber/main.lua.d/51-audient-id14.lua` | Forces `api.alsa.soft-mixer = true` (PipeWire never touches the broken hardware mixer; volume is software-only) and assigns the custom profile-set below. |
| `~/.config/alsa-card-profile/mixer/profile-sets/audient-id14.conf` | Replaces the bogus surround profiles with a proper **Stereo Output** profile (stereo → hardware channels 1/2; headphones mirror these via the device's internal main mix). Pro Audio profile remains available for DAW use. |

One-time actions also performed:
- Hardware mixer pinned at 127/127/127/127 (0 dB) — the only setting where L=R.
- Removed poisoned WirePlumber saved state (`~/.local/state/wireplumber/`): the
  Pro Audio sink had been saved at channelVolumes=0.0 + muted (why the device went
  silent), plus stale surround-profile route entries.
- New sink `alsa_output.usb-Audient_Audient_iD14-00.analog-stereo-mains` set as
  default, 50% volume.

Verified after the fix: desktop volume sweep 30/70/100/50% leaves the hardware
mixer untouched at 127×4 and software balance at 0.00; left/right test sounds play.

## Optional hardening (needs sudo, not required for the fix to work)

```bash
# Persist hw mixer state system-wide so ALSA restores 127x4 on every hotplug/boot
# (defends against the device powering up with the right channel attenuated):
sudo alsactl store

# System-wide copies (only useful if other users log into this machine):
sudo mkdir -p /etc/alsa-card-profile/mixer/profile-sets
sudo cp ~/.config/alsa-card-profile/mixer/profile-sets/audient-id14.conf /etc/alsa-card-profile/mixer/profile-sets/
sudo tee /etc/udev/rules.d/91-pipewire-alsa-audient.rules > /dev/null <<'EOF'
SUBSYSTEM=="sound", ACTION=="change", KERNEL=="card*", SUBSYSTEMS=="usb", ATTRS{idVendor}=="2708", ATTRS{idProduct}=="0008", ENV{ACP_PROFILE_SET}="audient-id14.conf"
EOF
```

## Revert

Delete the two config files above and restart the stack:
`systemctl --user restart pipewire pipewire-pulse wireplumber`

## Rocksmith 2014 + wineASIO (low-latency guitar)

Optional companion to the imbalance fix, for playing Rocksmith 2014 through the
iD14 with low-latency ASIO input under Proton.

- **`fix-audient-id14.sh apply --wineasio`** — the imbalance fix *plus* a rule
  that pins the iD14 **capture** clock to quantum 512 (`node.force-quantum`).
  Without it the capture defaults to its own 128-frame domain while wineASIO runs
  at 512; the cross-domain resampler then feeds the game silence ("no input"),
  then crackle. Adds ~11 ms capture latency, so plain `apply` leaves it off.
- **`setup-rocksmith.sh`** — first-time setup *from scratch* (works on a fresh
  clone, no bundle): installs PipeWire-JACK, downloads GE-Proton + RS_ASIO from
  upstream, writes the helper scripts / `RS_ASIO.ini` / prefix `.reg` inline,
  patches `Rocksmith.ini`, then calls `fix-audient-id14.sh apply --wineasio`.
  wineASIO has no clean prebuilt download, so supply it via `WINEASIO_DEB=`
  (KXStudio .deb), `WINEASIO_DIR=`, a system install, or a `./rocksmith/` bundle.
- **`backup-rocksmith.sh`** — snapshots the Rocksmith/wineASIO layer (wineASIO
  DLLs, RS_ASIO + the tuned `RS_ASIO.ini`/`Rocksmith.ini`, helper scripts, the
  prefix `.reg`, launch options) into `./rocksmith/`. That folder is
  `.gitignore`d (it holds copyrighted binaries) — each user regenerates it.
- **`restore-rocksmith.sh`** — rebuilds after an OS reformat by replaying an
  exact `./rocksmith/` snapshot (vs `setup`, which fetches current upstream),
  then calls `fix-audient-id14.sh apply --wineasio`.

All three auto-detect the Steam library (override `STEAM_LIBRARY=/path`).

**Reboot-safe:** all of the above is WirePlumber config + on-disk files +
Steam launch options that load automatically every boot — you never re-run
anything per reboot; `restore-rocksmith.sh` is only for a fresh OS install.

## Note for WirePlumber 0.5+ (future Ubuntu upgrade)

The Lua config format is WirePlumber 0.4-only. After an upgrade to 0.5+, replace
the Lua file with a `~/.config/wireplumber/wireplumber.conf.d/` fragment using
`monitor.alsa.rules` (same two properties).
