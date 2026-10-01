# HDMI recovery rollout

Prepared on 2026-09-23 for ThinkPad P14s Gen 5 AMD; combined stack promoted to
the default on 2026-10-01 after stable daily use. See
[the research](HDMI-RESUME-RESEARCH.md) for evidence and limitations.

## What is implemented

The default configuration has explicit, idempotent Lua DPMS actions (`{ action = "on" }`
and `{ action = "off" }`) and Hyprland stdout/file logging. Under UWSM,
stdout reaches the persistent user journal instead of being lost with the
runtime directory on reboot. Logging may include window/application metadata;
keep captures local and redact before sharing.

The default configuration now uses the previously tested `hdmi-combined` stack.
The `hdmi-display`, `hdmi-kernel`, and `hdmi-combined` specialisations are removed
from new generations; existing generations are not deleted.

| Boot entry | Kernel | Hyprland / Aquamarine | Mesa / Hyprland portal |
| --- | --- | --- | --- |
| Default (formerly `hdmi-combined`) | 6.18.53 | 0.56.2 / 0.15.1 | 26.2.3 / 1.4.1 |

Versions are those in the current lock. A dedicated `nixpkgs-display` input pins
only the kernel/display closures; the base `nixpkgs` and AI-tools input were not
updated. Both Mesa architectures and the portal accompany the newer compositor.
No ABI-incompatible library substitution, GPU parameters, BIOS flash, firmware
change, monitor modeset, or automatic suspend was added.

## Deploy

Save work first. Use the repository's supported wrapper:

```sh
rebuild
```

It uses current tracked local worktrees, runs the full compatibility checks,
asks for sudo, and installs the combined stack as the normal default boot
entry. It intentionally restarts Shelllist and its daemons, including the
bar-daemon-owned idle process. Do not run a separate standalone hypridle daemon.

Do not use raw `nixos-rebuild --flake /etc/nixos`: historical local lock entries
can select a Shelllist module without `programs.shelllist.displays`. The
`local-build`/`rebuild` snapshot workflow solves that mismatch without changing
or committing the other projects' worktrees.

Verify the default configuration after activation:

```sh
grep 'dpms' ~/.config/hypr/hypridle.conf
hyprctl configerrors
hyprctl version
uname -r
journalctl --user -u wayland-wm@hyprland.desktop.service -n 30 --no-pager
```

The three DPMS commands must contain `action =`. Check `hyprctl configerrors`
and that compositor logs reach the journal.

Reboot when convenient into the normal default entry; no `hdmi-*` selection is
needed. `hyprctl version` and `uname -r` should match the table after reboot.
A live rebuild does not replace the running kernel or compositor. Save work
before restarting the graphical session or rebooting.

## Verification and rollback

Verify HDMI recovery on the default entry with the same suspend/resume checks
used for `hdmi-combined`.

Keep the laptop panel available while testing by disabling the external-only
preference in Battery & Power. That is a user preference, not silently rewritten
by these changes. Record whether the connection is native HDMI or a dock.
Repeat short and long suspends, including multiple cycles per boot. Do not
combine a refresh-rate change or BIOS update with the first comparison.

Rollback: choose a **previous generation** in systemd-boot (hold Space during
startup if hidden). Older generations retain their original default and
`hdmi-*` entries. The new default is no longer the old-stack fallback.
No firmware downgrade is needed. Keep the previous known-good
generation until repeated physical tests succeed. A successful Nix build alone
does not establish reliable physical recovery.

## Evidence to collect

After a failed attempt and reboot, retain the previous boot's logs:

```sh
journalctl -b -1 _SYSTEMD_USER_UNIT=wayland-wm@hyprland.desktop.service --no-pager
journalctl -b -1 -k --no-pager
journalctl -b -1 -u systemd-suspend.service --no-pager
```

When the session is still reachable, capture these before resetting it:

```sh
hyprctl -j monitors all
for connector in /sys/class/drm/card*-HDMI-A-* /sys/class/drm/card*-eDP-*; do
  printf '\n%s\n' "$connector"
  cat "$connector/status" "$connector/enabled"
  wc -c < "$connector/edid"
done
```

No commands above change display state. The regression check
`checks.x86_64-linux.sleep-recovery` verifies evaluated DPMS commands, logging,
minimum combined-stack versions on the default configuration, matching Mesa
architectures, and removal of the experimental boot variants.
