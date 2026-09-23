# HDMI resume research — ThinkPad P14s Gen 5 AMD

Research date: 2026-09-23. Source changes prepared, **not activated**. No sleep,
DPMS, VT-switch, driver-reset, firmware-update, or session-restart experiment
was performed.

Implementation follow-up: [HDMI-RECOVERY-ROLLOUT.md](HDMI-RECOVERY-ROLLOUT.md)
documents the corrected hooks, persistent compositor logging, and independent
kernel/display boot candidates. The full evaluation mismatch described below
was resolved using the repository's current-worktree `local-build` workflow;
there was no need to alter Shelllist's source or refresh all dependency pins.
These research-time observations are retained as history.

## Conclusion and first action

**Fix the DPMS command syntax first.** The installed wake/idle configuration
passes strings to a Hyprland Lua API that expects an action table. In this
version, the strings silently select **toggle**, not the requested on/off action.
This is a confirmed configuration defect, not just a hardware hypothesis.

There are also relevant, merged fixes missing from both the installed
Aquamarine backend and the installed Linux kernel. Test those separately if
correcting the command syntax does not resolve recovery. The logs do not yet
prove which layer caused HDMI's repeated removal/recreation.

## 1. Confirmed local configuration defect

Installed `~/.config/hypr/hypridle.conf` contains:

```text
after_sleep_cmd=hyprctl dispatch 'hl.dsp.dpms("on")'
on-resume=hyprctl dispatch 'hl.dsp.dpms("on")'
on-timeout=hyprctl dispatch 'hl.dsp.dpms("off")'
```

For **Hyprland v0.55.4**, `hlDpms()` calls `tableToggleAction()`.
`tableToggleAction()` immediately returns `TOGGLE_ACTION_TOGGLE` if its argument
is not a Lua table. Otherwise it reads the table's `action` field. Thus **both
strings above mean toggle**. A wake callback can turn a display off if it is
already on, and two callbacks are not idempotent. An `ok` response does not
establish that the intended action was selected.

Verified against the exact release's source, not just current documentation:

- [hlDpms, v0.55.4](https://github.com/hyprwm/Hyprland/blob/v0.55.4/src/config/lua/bindings/LuaBindingsDispatchers.cpp#L288-L301)
- [tableToggleAction, v0.55.4](https://github.com/hyprwm/Hyprland/blob/v0.55.4/src/config/lua/bindings/LuaBindingsInternal.cpp#L442-L450)
- [Upstream resume report corrected after finding an invalid DPMS argument](https://github.com/hyprwm/aquamarine/issues/308#issuecomment-4794379017).
  That report used the wrong table key, rather than a string, but reached the
  same silent-toggle fallback. It is supporting evidence, not our reproduction.

Prepared in `home.nix`:

```nix
after_sleep_cmd = "hyprctl dispatch 'hl.dsp.dpms({ action = \"on\" })'";
# In the 420-second idle listener:
on-timeout = "hyprctl dispatch 'hl.dsp.dpms({ action = \"off\" })'";
on-resume = "hyprctl dispatch 'hl.dsp.dpms({ action = \"on\" })'";
```

Validation: Nix parsing, isolated evaluation of `home.nix`'s hypridle settings,
assertions on all three commands and preservation of lock-before-sleep, and
`git diff --check` passed. Full NixOS/Home Manager evaluation was blocked by an
existing source/locked-input mismatch: `programs.shelllist.displays` is absent
from the selected Shelllist module. It also reported an unlocked
`update-daemon` input. No lockfile changes were retained. Resolve the deployment
input mismatch before activation; this review does not claim a successful full
system build.

The running configuration still has the old syntax. After activation, verify
the generated hypridle file and restart the actual owner of the idle process
here (`bar-daemon`, which launches hypridle), rather than assuming a standalone
hypridle service owns it. Coordinate that restart; it manages more than idle.

## 2. Exact hardware and installed stack

| Component | Observed |
| --- | --- |
| Laptop | Lenovo ThinkPad P14s Gen 5 AMD, MTM `21ME002HMH` |
| CPU / GPU | Ryzen 7 PRO 8840HS / Radeon 780M, PCI `1002:1900` |
| AMD display engine | DCN **3.1.4**, Display Core 3.2.351 |
| BIOS | `R2LET41W`, **1.22**, dated 2026-05-21 |
| Sleep | `s2idle` only; firmware advertises S0/S4/S5, not S3 |
| Kernel | **6.18.39**, built July 18 |
| GPU firmware package | `linux-firmware-20260622`; DMUB `0x08005D00` |
| Compositor | **Hyprland 0.55.4**, commit `a0136d8c04687bb36eb8a28eb9d1ff92aea99704` |
| Display backend | **Aquamarine 0.11.0** |
| Monitor | Iiyama `PL3493WQ`, HDMI-A-1, 3440×1440 at 75.05 Hz, 8-bit XRGB |

Aquamarine 0.11.0 is confirmed by `hyprctl version`, the packaged Hyprland ELF
RUNPATH/NEEDED entries, and the pinned Nix expression. A different Aquamarine
version also exists in the system closure for other software; its presence does
not upgrade the compositor's backend.

Lenovo's [model specification](https://psref.lenovo.com/syspool/Sys/PDF/ThinkPad/ThinkPad_P14s_Gen_5_AMD/ThinkPad_P14s_Gen_5_AMD_Spec.pdf)
lists native HDMI up to 4K60 plus USB-C DisplayPort support and Linux offerings.
The [Arch model page](https://wiki.archlinux.org/title/Lenovo_ThinkPad_P14s_(AMD)_Gen_5)
identifies the T14 Gen 5 AMD as a closely related platform and documents s2idle,
not S3. Do not generalize Intel P14s, T14s, or later-generation BIOS reports to
this machine.

**Physical connection still needs confirmation:** built-in HDMI socket, or a
USB-C/dock adapter? HDMI-A-1 suggests an HDMI path but does not alone document
the cable route. UCSI manages USB-C; its timeout is not proof that it caused a
failure on the built-in HDMI connection.

## 3. What the latest failure establishes

Boot `b0e899655ebe483dbe1e6915dc981242`, local time:

- Ordinary suspend at 15:13:19; return at 19:13:10, not hibernation.
- AMD SMU successfully resumed. Userspace and fingerprint verification ran.
- Hypridle executed the **intended** DPMS-on command at 19:13:10; source review
  now shows that command actually requested toggle.
- UCSI connector-status timeout at 19:13:12.
- HDMI output objects replaced around 19:13:15–16 and 19:13:25–26.
- Daemon policy switched from `settling` to `external` at 19:13:16.
- Qt reported no outputs at 19:13:25; a fresh boot followed at 19:14:59.

These are compositor/Wayland output losses. Without contemporaneous DRM
connector state and Aquamarine logs, they do not prove electrical disconnection,
a cable defect, failed EDID reading, or a particular kernel bug. The five-second
fallback policy did not prevent the failure, but correcting that policy alone
cannot repair a stalled display backend or an unintended DPMS-off command.

## 4. Aquamarine: relevant fixes missing from 0.11.0

### Suspend bookkeeping — merged #254, released in 0.12.0

[Aquamarine #254](https://github.com/hyprwm/aquamarine/pull/254) clears stale
page-flip/frame state on restore and adds recovery for stale flips during
modesetting. Stale state can otherwise prevent new frames after the hardware
has slept. Comparing v0.11.0 with v0.12.0 confirms this code is absent from the
installed release. The installed library also lacks its new recovery strings.

### AMD 780M DPMS wedge — merged #312, released in 0.13.0

[Issue #304](https://github.com/hyprwm/aquamarine/issues/304) reports a Radeon
**780M**, Aquamarine **0.11.0** display wedge after DPMS off/on: IPC still answers,
DPMS says on, but display output does not recover. The report includes another
AMD machine and follow-up reproduction. This resembles our partial-userspace
recovery, but is not an exact laptop/native-HDMI reproduction.

[PR #312](https://github.com/hyprwm/aquamarine/pull/312), merged July 8, replaces
the earlier timing heuristic with deterministic frame-state cleanup and
coalescing of racing commits. It explicitly addresses #304. Prefer testing a
coherent released stack containing this fix over assuming #254 alone is enough.

As retrieved on September 23, `nixos-unstable` packages **Hyprland 0.56.2** and
**Aquamarine 0.15.1**. These are a candidate coordinated userspace update, not a
validated fix on this laptop. Do not drop a newer shared library into the old
compositor: Aquamarine releases change ABI, and Hyprland/plugins must match.

Avoid 0.15.0 specifically as a test target: it introduced a disconnected-output
teardown regression. [0.15.1](https://github.com/hyprwm/aquamarine/releases/tag/v0.15.1)
includes [#410](https://github.com/hyprwm/aquamarine/pull/410), releasing outputs
on disconnect. This newer regression **cannot explain our installed 0.11.0**.

An [older report on the exact laptop family](https://github.com/hyprwm/Hyprland/issues/7819)
describes external-output failure on P14s Gen 5 AMD / 780M / NixOS. However, it
used a Thunderbolt dock, two 4K displays, and Hyprland 0.43.0. It supports
investigating display management, not claiming a known native-HDMI hardware bug.

## 5. Linux AMD HDMI: a hardware-path-specific fix

The current 6.18 LTS release is **6.18.53** (September 21). A fix after our
6.18.39 is unusually relevant:

[Increase HDMI AV mute wait from 2 to 3 frames](https://github.com/gregkh/linux/commit/3c2ae9509717c4a140ae6217dddb76d67ce947f4)
explains that some HDMI monitors need additional General Control Packets before
the timing generator is disabled, especially after re-establishment with HDMI
2.0 scrambling. Insufficient time caused garbled output after suspend.

This is not just a similarly named GPU: [DCN 3.1.4's function table](https://github.com/gregkh/linux/blob/v6.18.39/drivers/gpu/drm/amd/display/dc/hwss/dcn314/dcn314_init.c)
uses `dcn30_set_avmute`. The [6.18.39 implementation](https://github.com/gregkh/linux/blob/v6.18.39/drivers/gpu/drm/amd/display/dc/hwss/dcn30/dcn30_hwseq.c)
waits two frames; [6.18.53](https://github.com/gregkh/linux/blob/v6.18.53/drivers/gpu/drm/amd/display/dc/hwss/dcn30/dcn30_hwseq.c)
waits three. **The fix applies to this GPU's code path.** Its documented symptom
is garbled output, not a proven match for our complete output loss.

The newer LTS also contains [DPMS pipe-context correction](https://github.com/gregkh/linux/commit/c54ef628c74c0f2f7220621f92a1df5e848e710a)
and HDMI color/InfoFrame fixes. This makes an updated **same-series LTS** a
reasonable separate test; jumping to a new major kernel is not required.

EDID adds a useful controlled test: the current 75.05-Hz mode has a **438.54-MHz**
pixel clock; native 59.97-Hz is **319.75 MHz**. At 8-bit RGB, the latter falls
below HDMI's 340-MHz high-TMDS-rate threshold. Testing native resolution at 60 Hz
can therefore help isolate high-rate/SCDC link recovery, not just reduce GPU
load. The monitor advertises SCDC and a 600-MHz TMDS character-rate maximum,
so 75 Hz is not inherently unsupported. The earlier lower-resolution color test
was not a controlled suspend/resume test.

## 6. Firmware, NixOS, and tempting but unproven workarounds

- `fwupdmgr get-releases` for GUID `6b5ce143-7c0e-4ca3-aa72-a620dba1c41d`
  offers BIOS **1.23**, [LVFS release 149767](https://fwupd.org/lvfs/releases/149767).
  Published notes list diagnostics/security changes, **not an HDMI resume fix**.
  They warn that upgrading prevents rollback below 1.23. Treat it as a separate
  firmware/security decision, not the first reversible HDMI experiment.
- Installed BIOS 1.22's advertised sleep change addresses intermittent fan spin.
- NixOS does not implement its own HDMI driver. Linux amdgpu/DC handles KMS,
  hotplug, EDID and the link; Aquamarine issues DRM commits; Hyprland exposes
  outputs; our daemon controls layouts; hypridle issues DPMS commands.
- Existing NixOS config enables amdgpu early in initrd, graphics and redistributable
  firmware. The [nixos-hardware P14s AMD Gen 5 module](https://github.com/NixOS/nixos-hardware/blob/master/lenovo/thinkpad/p14s/amd/gen5/default.nix)
  and its parent modules contain no dedicated HDMI-resume fix. Their old kernel
  minimums are already exceeded.
- `amdgpu.dcdebugmask=0x10` disables **panel self refresh**; the model wiki suggests
  it for flicker/lag. It is not an established native-HDMI resume fix. PSR and
  Panel Replay also have separate flags in this kernel. Do not bundle masks
  without a specific test hypothesis.
- Do not try `mem_sleep_default=deep`: this machine exposes no S3/deep state.
- Do not start with `amdgpu.dc=0`, random ACPI overrides, disabling atomic KMS,
  or unloading amdgpu under a running desktop. These are risky or unrelated and
  would obscure the concrete findings above.

## 7. Recommended test sequence

1. **Activate only the corrected DPMS hooks**, after resolving the unrelated
   deployment-input mismatch. Confirm the running idle process uses the new
   file. Keep lock-before-sleep enabled.
2. Add persistent compositor/backend diagnostics for user-initiated tests. In
   the existing Lua `hl.config` table, `debug = { disable_logs = false,
   enable_stdout_logs = true }` enables logs that UWSM can send to the journal.
   Diagnostics can include application/window metadata; retain them locally and
   inspect/redact before sharing. Do not rely solely on runtime-directory logs,
   which disappear on reboot.
3. Keep the laptop panel available during testing. Record DRM connector status,
   enabled state and EDID size alongside `hyprctl -j monitors all` before/after
   resume. A two-second snapshot alone can miss the brief dropouts seen here;
   collect DRM uevents/compositor monitor events too.
4. If failure remains, test **newer matched Hyprland/Aquamarine** while holding
   kernel/firmware constant. Retain the known boot generation and save work
   before restarting the compositor. Validate Lua configuration and plugin ABI.
5. Separately test **6.18.53 LTS**, keeping the userspace version fixed. Use a
   boot-only generation/specialisation with a rollback entry, not a surprise
   live session replacement. Do not silently update the entire flake to change
   one component.
6. If necessary, test 3440×1440 at ~60 Hz; then compare the same hardware under
   another compositor. A USB-C-to-DisplayPort route is another isolation test if
   available, not evidence that native HDMI is repaired.

Repeat short and long suspends and more than one recovery per boot. A successful
build or one successful wake is not proof of reliability. Test hibernation
separately; the historical pre-BIOS-update hibernation failure was different.

Interpretation during failure:

| Observation | Stronger lead |
| --- | --- |
| DRM connected, EDID readable; Hyprland absent/0×0 output or commit errors | Aquamarine/compositor state |
| Outputs present, DPMS false immediately after wake | Wake/idle command ordering or syntax |
| DRM disconnected / EDID absent across compositors | Link, monitor, driver, firmware or physical route |
| AMD flip/DMUB timeouts, errors across compositors | Kernel/firmware; capture AMD display debug state |

Useful kernel guidance: [AMD display debugging](https://docs.kernel.org/gpu/amdgpu/display/dc-debug.html)
and [AMD platform debugging](https://docs.kernel.org/arch/x86/amd-debugging.html).
AMD's GitLab issue pages were bot-protected in this environment, so claims above
use accessible merged kernel commits rather than pretending to have reviewed
those blocked discussions. General searches did not establish a verified
native-HDMI fix specific to MTM 21ME002HMH.
