# HDMI Troubleshooting Notes

Date started: 2026-06-11

Machine: Lenovo ThinkPad running NixOS 26.05 with Hyprland.

Problem: HDMI output shows incorrect colors, described as pink and green tinting.

## Known Good Hardware

- The monitor is known good.
- The same monitor works correctly from a PC connected to another monitor input.
- The HDMI cable/connector path is believed good.
- The laptop output previously worked correctly when the laptop was running Windows.

## Current Linux Stack

- GPU: AMD Phoenix/HawkPoint iGPU.
- Kernel driver in use: `amdgpu`.
- Kernel command line currently has no custom display-related parameters.
- NixOS config enables `hardware.graphics.enable = true`.
- Hyprland is the active desktop/compositor.
- GDM and GNOME are disabled.

Observed from `lspci -nnk`:

- GPU device: `Advanced Micro Devices, Inc. [AMD/ATI] HawkPoint1 [1002:1900]`
- Driver: `amdgpu`

Observed from kernel log:

- `amdgpu` initializes successfully.
- Display Core initializes as `Display Core v3.2.351`.
- Kernel reports `DP-HDMI FRL PCON supported`.
- Kernel sees these connectors:
  - `eDP-1`
  - `HDMI-A-1`
  - `DP-1` through `DP-6`

Observed from `/sys/class/drm` while HDMI is connected:

- `card1-HDMI-A-1`: `connected`, `enabled`
- `card1-eDP-1`: `connected`, `disabled`
- HDMI advertised modes include:
  - `3440x1440`
  - `2560x1440`
  - `1920x1080`
- EDID monitor name appears to be `PL3493WQ`.

## Config Changes Already Present

Display automation in `home.nix`:

- Added `hypr-monitor-auto`.
- It checks `/sys/class/drm/card*-DP-*/status` and `/sys/class/drm/card*-HDMI-A-*/status`.
- When an external display is connected, it runs:
  - `hyprctl keyword monitor ",preferred,auto,1.25"`
  - `hyprctl keyword monitor "eDP-1,disable"`
- When no external display is connected, it runs:
  - `hyprctl keyword monitor "eDP-1,preferred,auto,1.25"`

Hyprland config in `config/hypr/hyprland.conf`:

- Default monitor rule currently:
  - `monitor = ,preferred,auto,1.25`
- `hypr-monitor-auto` is started with:
  - `exec-once = hypr-monitor-auto`
- `nwg-displays` can be launched with:
  - `SUPER+P`
- Hyprland color management/HDR settings currently include:
  - `cm_enabled = false`
  - `cm_auto_hdr = 0`

System packages:

- `nwg-displays` is installed.
- DRM diagnostic tools are installed:
  - `drm_info`
  - `modetest` from `libdrm`
  - `edid-decode`

AMD module parameters observed live:

- `deep_color=0`
- `dc=-1`
- `dcdebugmask=0`
- `dcfeaturemask=2`

## Things Already Tried

- Tried lower display resolution.
- Result: no change to the pink/green color problem.

## Current Assessment

The problem does not look like a simple broken monitor, broken HDMI cable, or excessive resolution/bandwidth issue, because:

- The monitor works from another PC.
- The same laptop/cable path worked under Windows.
- Lowering resolution did not change the symptom.
- The Linux kernel detects and enables HDMI successfully.

More likely areas to test next:

- AMD DC / HDMI color format behavior.
- RGB vs YCbCr output selection.
- Color depth / bpc handling.
- EDID interpretation or override.
- Firmware/kernel regression in the AMD display stack.

Hyprland/wlroots is now less likely because the color difference is also visible on a Linux TTY.

## Next Test Ideas

- Inspect DRM connector properties with a tool such as `modetest` or `drm_info`.
- Decode the HDMI EDID and check advertised color formats/depths.
- Test another compositor/session only as a cross-check after DRM properties are inspected.
- Try forcing HDMI mode with an explicit refresh rate in Hyprland.
- Try kernel parameters affecting AMD display behavior, one at a time.

## Log

### 2026-06-11

- Inspected `/etc/nixos` for HDMI/display-related configuration.
- Found current troubleshooting is mostly in Hyprland/Home Manager rather than kernel or EDID config.
- Confirmed live GPU is AMD using `amdgpu`.
- Confirmed HDMI is connected/enabled as `card1-HDMI-A-1`.
- Confirmed laptop panel is disabled while HDMI is active, matching `hypr-monitor-auto`.
- Confirmed lower resolution had already been tried with no change.
- Tested Linux TTY with `Ctrl+Alt+F3`.
- Result: laptop screen TTY and external monitor TTY still show different colors.
- Implication: color mismatch is visible outside Hyprland, so Hyprland color management/compositor configuration is unlikely to be the primary cause.
- Current boot after the TTY test shows both `card1-eDP-1` and `card1-HDMI-A-1` as `connected` and `enabled`.
- `drm_info` and `modetest` are not currently installed.
- Added `drm_info`, `edid-decode`, and `libdrm` to `environment.systemPackages` in `/etc/nixos/configuration.nix`.
- Changed `/etc/nixos/configuration.nix` ownership to `laufan:users`, matching the rest of the editable config files.
- Rebuilt system so the DRM tools are available in `/run/current-system/sw/bin`.
- After rebuild, both laptop panel and HDMI display are active:
  - `card1-eDP-1`: `connected`
  - `card1-HDMI-A-1`: `connected`
- `drm_info` results for HDMI:
  - DRM node: `/dev/dri/card1`
  - Driver: `amdgpu`
  - HDMI connector object ID: `102`
  - HDMI connector type/name: `HDMI-A-1`
  - Status: `connected`
  - CRTC: `84`
  - Link status: `Good`
  - `Broadcast RGB`: `Automatic`
  - `max bpc`: `8`
  - `content type`: `Graphics`
  - `Colorspace`: `Default`
  - `HDR_OUTPUT_METADATA`: empty blob
  - `vrr_capable`: `1`
- `modetest -M amdgpu -c` confirms HDMI property names and IDs:
  - connector `102`
  - `Broadcast RGB` property ID `103`, values `Automatic=0`, `Full=1`, `Limited 16:235=2`
  - `max bpc` property ID `104`, range `8..16`, current `8`
  - `content type` property ID `105`, current `Graphics`
  - `Colorspace` property ID `106`, current `Default`
- Decoded HDMI EDID with `edid-decode`:
  - Monitor name: `PL3493WQ`
  - EDID says base display is RGB color.
  - CTA block also advertises YCbCr 4:4:4 and YCbCr 4:2:2.
  - CTA Video Capability Data Block says RGB quantization and YCbCr quantization are selectable.
  - HDMI vendor block advertises `DC_30bit` and `DC_Y444`.
  - HDMI Forum block advertises SCDC and 600 MHz TMDS character rate.
  - HDR static metadata block is present.
- Tried `modetest -M amdgpu -w 102:103:1` to force HDMI `Broadcast RGB` to `Full`.
  - Result: failed with `CONNECTOR 102 has no 103 property`.
  - Cause: this `modetest` syntax expects property name, not property ID.
- Retried with correct property-name syntax: `modetest -M amdgpu -w 102:"Broadcast RGB":1`.
  - Result without sudo: failed with `Permission denied`.
- Retried the same command with sudo: `sudo modetest -M amdgpu -w 102:"Broadcast RGB":1`.
  - Result: still failed with `Permission denied`.
  - Likely cause: Hyprland/logind currently owns DRM master for `/dev/dri/card1`; root can open the DRM node, but it cannot change KMS connector properties while another process is the active DRM master.
