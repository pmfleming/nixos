# Sleep and hibernation recovery review — 2026-09-17

The failure predates the firmware update. The latest reported failure occurred
after the update, but its recorded signature differs from the earlier failed
hibernation. A kernel message saying it returned from suspend is not evidence
that the user regained a working display/session.

## Confirmed history (Europe/Amsterdam)

| Date | Evidence | Interpretation |
| --- | --- | --- |
| September 2 and 7 | Suspend entries without a subsequent return in those boots, followed by new boots. | Consistent with the recurring recovery problem; missing journal entries alone cannot identify the cause. |
| September 7 | Configuration commit `cf8d680` enabled fwupd and changed `HandlePowerKey` to `ignore`. | Accidental re-suspend while trying to recover a black screen was already addressed. |
| September 11 | Configuration commit `8333bee` enabled a 64-GiB swapfile and systemd initrd EFI resume. | Persistent swap and boot resume integration were already added. |
| September 13, 17:26–18:02 | Suspend-then-hibernate woke after 30 minutes and entered hibernation. AMD SMU commands failed; the kernel logged `Wakeup pending. Abort CPU freeze`, followed by `amdgpu_device_ip_resume failed (-62)` and `PM: failed to restore async: error -62`. ACPI methods then timed out. | Confirmed platform/device failure during hibernation and its abort/recovery, before the firmware update. |
| September 15, 00:38 | The initrd read the EFI hibernation location and attempted resume at offset 1832960. It logged `PM: Image not found (code -22)` and continued a fresh boot. | Resume discovery ran, but no valid image was restored. This does not establish that the offset was wrong; the preceding hibernation had failed. |
| September 15, 02:03 onward | Boot DMI reports BIOS `R2LET41W (1.22)`, replacing `R2LET38W (1.19)`. fwupd history records the 1.19 → 1.22 update. | Firmware update is confirmed applied. The published release description mentions intermittent fan spin during sleep, not a confirmed fix for these recovery failures. |
| September 16, 15:09 → September 17, 01:19:48 | Ordinary s2idle suspend returned after roughly ten hours. AMD SMU logged successful resume. Hypridle ran its DPMS-on command. | The kernel and user processes resumed; this does not prove the desktop was usable. |
| September 17, 01:19:49–01:20:00 | HDMI output was repeatedly removed/recreated; Qt twice reported no outputs. Shelllist rebuilt surfaces and reported an overlay binding loop. | Display topology was unstable after wake. The bar cannot repair missing compositor outputs. |
| September 17, 01:20:08–01:20:59 | Fingerprint verification matched; power-button events were processed; application sampling continued. The next boot starts at 01:22:10. | The latest failure left substantial userspace functioning. Display/compositor recovery is the strongest current lead; the journal does not prove precisely which component kept the screen unusable. |

No post-update hibernation attempt was found in the journal reviewed through
September 17, 16:17. The pre-update hibernation fault must not be presented as
proof that the same fault persists on BIOS 1.22.

## Concrete monitor-policy defect and prepared fix

`config/scripts/hypr-monitor-auto.sh` previously treated a DRM connector's
`connected` status as sufficient to disable `eDP-1`. It neither checked for an
active external output in Hyprland nor retained a fallback on command failure.
It reacted only to monitor/config events, so a missed event could leave a stale
layout indefinitely. It also forced rule application on events caused by its
own monitor changes.

The prepared change:

- Requires an enabled, nonzero-size DP/HDMI output in Hyprland before selecting
  an external-only layout or disabling the laptop panel.
- Enables the internal panel while the cable is connected but the compositor
  output is absent, then rechecks every two seconds when the event stream is
  quiet. Normal idle DPMS blanking does not trigger this fallback.
- Bounds compositor calls, keeps failed operations retryable, and avoids
  reapplying unchanged layouts in response to their own events.
- Restores saved layouts after recovery and resets cached policy on config
  reload or socket reconnect.

This fixes a reproducible policy defect consistent with the latest output-loss
logs. It is not proof of the underlying hardware cause, and it cannot repair an
AMD GPU that has failed to restore. The change is prepared in the source tree;
no system/Home Manager activation or live monitor mutation was performed during
this review.

Validation passed: the Nix `monitor-auto` regression check, the repository-wide
ShellCheck check, and `git diff --check`. Tests cover missing external outputs,
missing IPC replies, saved-layout restoration, failed commands, periodic retry,
config reload, and settling after self-generated monitor events. These are
automated policy checks, not physical suspend/hibernate validation.

## September 19 follow-up: daemon-owned docking policy

In boot `c952e2193dd444d089594d2cac35fdcc`, ordinary suspend returned at
06:46:51 and AMD SMU reported successful resume. HDMI appeared and disappeared;
Qt reported no outputs at 06:46:57 and 06:47:13. A USB-C connector-status query
also timed out at 06:46:54. Closing the lid at 06:47:17 triggered another ordinary
suspend at 06:47:18. This attempt is evidence of an unstable display/session
handoff, not proof of a hibernation failure or a fully recovered GPU.

The earlier script fix was installed, but still switched to external-only as
soon as an output appeared, cached successful fallback-rule submission without
verifying the resulting panel, and reconciled periodically only when the event
stream was quiet. These behaviours are now replaced by bar-daemon's display
policy, with its regression tests in `bar-daemon/src/display_policy/`:

- Keep the internal panel as a fallback until external topology is stable for
  five seconds; reset that evidence on resume and output replacement/loss.
- Reconcile every two seconds regardless of window/workspace event traffic.
- Recheck topology and sleep state before disabling the laptop panel, and retry
  missing fallback outputs rather than trusting the last policy label.
- Leave a working external mode alone rather than reapplying wildcard rules.
- Persist the external-only preference in the daemon and expose it in Battery
  & Power; Nix only sets `programs.shelllist.displays.enable = true`.

The old script, its tests, package, service and Nix test wiring have been removed
from this repository. Unit ordering/conflicts plus a daemon runtime ownership
check prevent the old service and new daemon from managing outputs together.
Activate the updated daemon/UI/Home Manager configuration together. This source
migration does not itself stop the running old service or change live displays.
The pre-existing deployment lockfile edits were not changed by this migration.

This does not establish a fix for the USB-C timeout or all physical wake cases.
External-only with a closed lid still depends on the compositor/driver restoring
the external connector; opening the lid remains the usable fallback when that
connector cannot be restored. No sleep, display-switch, GPU-reset or firmware
experiment was performed during this follow-up.

## September 23 follow-up: recovery still fails with daemon policy active

Boot `b0e899655ebe483dbe1e6915dc981242`, Europe/Amsterdam:

- Lid close initiated **ordinary suspend** at 15:13:19. It returned at
  19:13:10 when the lid opened. This attempt did not exercise hibernation.
- AMD SMU reported successful resume; user.slice thawed and Hypridle issued
  DPMS-on. This does not establish successful scanout or a usable session.
- At 19:13:12, UCSI again logged `GET_CONNECTOR_STATUS failed (-110)`.
  The timeout is correlated evidence, not proof of the HDMI failure's cause.
- The installed daemon reported `settling` at 19:13:10 and `external` at
  19:13:16. HDMI Wayland outputs were replaced around 19:13:15–16 and
  19:13:25–26. At 19:13:25, Qt explicitly reported **no outputs**.
- Fingerprint verification matched at 19:13:37; power-button events and app
  sampling continued through 19:14:21. A fresh boot began at 19:14:59.
  The journal does not show an orderly shutdown in between.

The earlier daemon migration was running, but did not prevent this failure.
Its five-second settling period expired before the last observed HDMI dropout.
Source inspection also reveals a blind spot: display reconciliation consumes
sleep events and a two-second timer, not compositor monitor add/remove events.
A disconnect/reconnect between samples can leave the same monitor signature
and escape stability invalidation. Wayland output replacement is not itself
proof that Hyprland's monitor ID changed. No renewed `settling` or `internal`
policy status was logged after the 19:13:25 dropout.

Recommended immediate isolation/mitigation: turn off the external-only
preference in Battery & Power so the internal panel remains enabled with HDMI
attached. This is not a proven GPU/firmware fix. A robust follow-up should
invalidate stability on monitor lifecycle events and retain the panel during
wake recovery rather than interpreting a few matching snapshots as proof of a
working external display. Increasing the delay alone cannot prove recovery.

Detailed compositor logs are missing from the persistent journal: Hyprland
announced that it disabled stdout logging at startup. Capture persistent
compositor logs and timestamped monitor/DPMS/DRM snapshots around the next
user-initiated wake to distinguish policy, lock-screen, and driver failures.
No live display settings, services, kernel parameters, or sleep configuration
were changed in this review; only these notes were updated.

## September 23 research update: confirmed DPMS command defect

See [HDMI-RESUME-RESEARCH.md](HDMI-RESUME-RESEARCH.md) for hardware identification,
upstream sources, missing Aquamarine/Linux fixes, and the ordered test plan.

**Correction to the earlier interpretation:** the logged
`hl.dsp.dpms("on")` command was intended to turn displays on, but Hyprland
0.55.4's Lua implementation interprets a non-table argument as **toggle**.
The existing idle `"off"` command also toggles. Thus the resume hook can turn
an already-awake output off again. Logs showing that command ran are not proof
that DPMS-on was requested.

`home.nix` now uses `hl.dsp.dpms({ action = "on" })` for both wake callbacks and
`hl.dsp.dpms({ action = "off" })` for idle blanking. These source changes are
**not activated**. Isolated settings evaluation and syntax checks passed; full
system evaluation is blocked by an unrelated Shelllist source/input mismatch,
as detailed in the research notes. Correct and activate the hooks before
attributing remaining failures to hardware or updating kernel/compositor.

This establishes a real configuration defect, not proof that it accounts for
every HDMI hotplug or the historical hibernation failure.

## Remaining validation

After activating the monitor fix, compare internal-panel-only and HDMI-connected
suspend recovery on the current firmware, recording DRM connector status,
Hyprland monitor state, DPMS state, and compositor logs across wake. The current
logs show output loss but do not contain enough compositor detail to separate
driver output loss from monitor-policy effects.

Test hibernation separately from suspend-then-hibernate on the current firmware.
If AMD restore errors recur, investigate the device/platform stages using the
[kernel power-management debugging procedure](https://www.kernel.org/doc/html/latest/power/basic-pm-debugging.html).
Its staged tests distinguish device restoration from platform callbacks; a
`shutdown` versus `platform` comparison is an experiment, not an established fix.
No sleep cycle, firmware flash, GPU reset, driver unload, or boot-parameter
change was performed during this review.

## Reproduce the evidence

```sh
# Failed hibernation before the firmware update.
journalctl -b 3e931bcbbd8049bab2414948c8bc00eb -k \
  --since '2026-09-13 17:56:15' --no-pager

# Subsequent boot attempted EFI-based resume but found no valid image.
journalctl -b a5df33edd33740e0ad13848c1b60dc7f --no-pager \
  -g 'hibernation image|Unable to resume|Image not found'

# Latest post-update recovery failure; userspace continued running.
journalctl -b c6cf84f5eff2448aa4cd65a74ad2705b \
  --since '2026-09-17 01:19:40' --no-pager

# Concise firmware history, avoiding unrelated machine metadata.
fwupdmgr get-history --json | jq '.Devices[] |
  {Name, Version, UpdateState, releases: [.Releases[] | {Version, Description}]}'
```
