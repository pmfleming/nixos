# Phase 1S graphics loader regression — 2026-11-05

The first Hyprland 0.57.1 deployment booted, but Ghostty reported that it could
not acquire an OpenGL context. The user returned to the previous generation.
This is a confirmed driver/application ABI incompatibility, independent of
workspace IPC and the historical suspend/HDMI recovery investigation.

## Failure evidence

Failed boot: `33bfdabf5d8c4d8a90dc9930bc89fb36`. The journal records Linux
6.18.60 and Hyprland 0.57.1 starting. Ghostty, hyprpaper and Quickshell then
failed to initialize their graphics contexts. Mesa's diagnostic identifies
`GLIBC_2.43` missing from the base application's glibc 2.42 `libm.so.6`, required
by `mesa-26.2.6/lib/libgallium-26.2.6.so`. hyprpaper repeatedly crashed.

The independently pinned display package set uses glibc 2.44, while the base OS
uses glibc 2.42. Assigning its prebuilt Mesa to `hardware.graphics.package`
therefore placed incompatible libraries in the application loader's search path.
The older 26.2.3 driver loads successfully with that same base OS loader.

The original acceptance tests missed this: nested clients used the active old
`/run/opengl-driver`, and the Quickshell smoke used the software renderer.
Successful compositor startup and workspace IPC did not exercise the new driver
inside the base OS Ghostty process.

## Repair and repeatable gate

`lib/display-mesa.nix` imports the display pin's Mesa recipe using the base OS
package graph. Both architectures retain Mesa 26.2.6 and their normal driver
sets. The architecture-independent SPIR-V data is shared from the native build;
it does not introduce a newer-libc runtime library. The display pin, kernel,
Hyprland/Aquamarine and portal versions remain the approved upgrade versions.

The display module rejects drivers built with a newer libc than the base OS.
The `graphics-driver-load` check additionally compiles a base OS process for
each architecture and calls `dlopen(..., RTLD_NOW | RTLD_LOCAL)` on every
installed Mesa shared library, including DRI, GBM, OpenGL and Vulkan drivers.
This checks actual dependency loading without a GPU or display server.

Run the gate against the frozen coordinated local source graph:

```sh
local-build build --attr checks.x86_64-linux.graphics-driver-load /etc/nixos --no-link
local-build check /etc/nixos
```

## Validation evidence

- The base OS loader probe rejects the failed display-pin driver and accepts
  the rolled-back driver and repaired driver. The failed-driver EGL probe
  independently reproduces `eglInitialize failed`.
- Both committed 64-bit and 32-bit driver-loading derivations passed. Each
  process reports glibc 2.42 while loading the repaired Mesa 26.2.6 libraries.
  The separate manual 64-bit run loaded 94 installed library paths, including
  symlink aliases.
- Base OS `eglinfo`, with the repaired EGL vendor JSON, DRI directory and GBM
  directory explicitly selected, creates AMD Radeon 780M OpenGL 4.6 contexts
  with Mesa 26.2.6. The rolled-back driver reports 26.2.3 in the same probe.
- A private Hyprland 0.57.1 compositor, private IPC/runtime, private home/data
  and non-activating D-Bus session ran actual Ghostty and Quickshell 0.3.2 with
  those same repaired driver paths. Ghostty mapped a window, logged
  `info(opengl): loaded OpenGL 4.6` and exited zero. Quickshell used its OpenGL
  backend, rendered Shelllist and logged AMD Radeon 780M / Mesa 26.2.6 for both
  Qt rendering contexts. Its IPC ping/status/list/quit and hidden-popover
  workspace smoke passed. No production service was restarted.
- Nix formatting, deadnix and statix passed after formatting the changed files.
- Full coordinated `local-build check` passed against the repair worktree,
  including all 63 evaluated host checks. The new graphics checks also passed
  independently for both architectures.

The GPU probes ran on the rolled-back kernel 6.18.53, under the existing parent
compositor. They establish application/driver loading and rendering, not the
new kernel's scanout, boot, sleep, hibernation or docking behavior. The repaired
generation has not been activated or rebooted during this investigation.

Transient raw logs: `/tmp/graphics-loader-old-failure.log`,
`/tmp/graphics-eglinfo-{working-baseline,failed-candidate,repaired-candidate}.log`,
`/tmp/graphics-driver-64-load.log`, `/tmp/repaired-graphics-session.log`, and
`/tmp/ipc-lycans14/{ghostty,shelllist-host}.log`. Durable automated evidence is
the Nix `graphics-driver-load` check and its derivation logs.

Both delayed update timers were stopped again after the rollback reboot.
Keep the hold until the repaired upgrade is confirmed working; Phase 2 remains
gated on that confirmation. A timer stop lasts only until the next reboot.
