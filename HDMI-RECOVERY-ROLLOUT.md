# HDMI recovery rollout

Prepared on 2026-09-23 for ThinkPad P14s Gen 5 AMD. See
[the research](HDMI-RESUME-RESEARCH.md) for evidence and limitations.

## What is implemented

All entries have explicit, idempotent Lua DPMS actions (`{ action = "on" }`
and `{ action = "off" }`) and Hyprland stdout/file logging. Under UWSM,
stdout reaches the persistent user journal instead of being lost with the
runtime directory on reboot. Logging may include window/application metadata;
keep captures local and redact before sharing.

The default configuration deliberately retains the original kernel and display
stack. Three NixOS specialisations allow independent tests:

| Boot entry | Kernel | Hyprland / Aquamarine | Mesa / Hyprland portal |
| --- | --- | --- | --- |
| Default, DPMS-only baseline | 6.18.39 | 0.55.4 / 0.11.0 | Original packages |
| `hdmi-display` | 6.18.39 | 0.56.2 / 0.15.1 | 26.2.3 / 1.4.1 |
| `hdmi-kernel` | 6.18.53 | 0.55.4 / 0.11.0 | Original packages |
| `hdmi-combined` | 6.18.53 | 0.56.2 / 0.15.1 | 26.2.3 / 1.4.1 |

Versions are those in the current lock. A dedicated `nixpkgs-display` input pins
only the candidate closures; the base `nixpkgs` and AI-tools input were not
updated. Both Mesa architectures and the portal accompany the newer compositor.
No ABI-incompatible library substitution, GPU parameters, BIOS flash, firmware
change, monitor modeset, or automatic suspend was added.

## Deploy

Save work first. Use the repository's supported wrapper:

```sh
rebuild
```

It uses current tracked local worktrees, runs the full compatibility checks,
asks for sudo, and installs the default configuration plus all three boot
entries. It intentionally restarts Shelllist and its daemons, including the
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

The three DPMS commands must contain `action =`. The default versions remain old
on purpose. Log enabling takes effect when Hyprland reads the new configuration;
check `hyprctl configerrors` and that new compositor logs reach the journal.

Reboot when convenient, choosing the appropriate `hdmi-*` specialisation in
the systemd-boot menu (hold Space during startup if hidden). Do not switch to a
different compositor/Mesa closure live or restart the compositor with unsaved
applications. `hyprctl version` and `uname -r` verify the selected test pair.

## Test order and rollback

1. Default entry: test only the DPMS correction, with diagnostics enabled.
2. If recovery still fails, select `hdmi-display` for a new userspace-only test.
3. Select `hdmi-kernel` for a separate new-kernel-only test.
4. Select `hdmi-combined` if testing both fixes together is needed.

Keep the laptop panel available while testing by disabling the external-only
preference in Battery & Power. That is a user preference, not silently rewritten
by these changes. Record whether the connection is native HDMI or a dock.
Repeat short and long suspends, including multiple cycles per boot. Do not
combine a refresh-rate change or BIOS update with the first comparison.

Rollback: choose the **default entry of this generation** to return to the
original stack with corrected hooks, or a **previous generation** to undo the
whole deployment. No firmware downgrade is needed. Keep the previous known-good
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
the fixed candidate versions, and independence of kernel/display boot variants.
