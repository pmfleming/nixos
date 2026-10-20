# NetworkManager and nm-daemon deployment

The host explicitly imports `inputs.nm-daemon.nixosModules.networkManager`.
This selects the adapter repository's validated stable NetworkManager package,
not its development target or the base OS package. The existing Wi-Fi backend,
connectivity checks, resolver mode and profile mDNS defaults remain unchanged.

`checks.daemon-ownership` verifies that the host selects that stable package and
Home Manager installs nm-daemon's matching packaged user unit. The normal
`rebuild` workflow captures the current local worktrees once, checks the frozen
graph, switches the system, then restarts the daemon/frontend stack. Do not use
persistent local input locks or replace the one live shared framework.

For this rollout the adapter repository adds IPv6 DNS decoding, current device
and reason names, six upstream backports, and a refreshed test-only
development revision. Stable remains released 1.58.1. Its provenance manifest at
`share/nm-daemon/networkmanager-provenance.json` identifies the source and six
backports; the version string alone does not.

## October 20, 2026 rollout

Baseline: running NetworkManager and nmcli 1.56.0; system generation 420,
`/nix/store/ycz7qcqmj76016lxswrawpxr8w9qhdbq-nixos-system-thinkpad-26.05.20260719.fd14620`.
The active backend is wpa_supplicant, with internal DHCP and keyfile profiles.

The user activated generation **421** on October 20. Read-only verification at
12:36 CEST found:

- System: `/nix/store/khbcahch96c0k52p0glgk8657aacl3f8-nixos-system-thinkpad-26.05.20260719.fd14620`.
- NetworkManager active since 12:33:57; D-Bus version and installed nmcli both
  **1.58.1**. D-Bus owner PID **504197** matches the systemd MainPID.
- NM unit executable: `/nix/store/c8wj9jkx1svq5fwvs049ndz1m5zbrcrr-networkmanager-1.58.1/sbin/NetworkManager`;
  its manifest contains the six reviewed backports. This is the tested package.
- Actual nm-daemon process executable:
  `/nix/store/gf34mqxiclhr3viwhr4j7zwsfsjj76bw-nm-daemon-0.1.0/bin/nm-daemon`;
  matches its loaded unit and the package that passed all 21 adapter checks.
- The v2 SecretAgent reports registered with NetworkManager-owned storage;
  Wi-Fi is active on `wlp2s0` and connectivity reports `connected:full`.
- Generation 420 remains available at the baseline path above.

The operator completed the privileged `/proc` executable check and reported:
`/nix/store/c8wj9jkx1svq5fwvs049ndz1m5zbrcrr-networkmanager-1.58.1/bin/NetworkManager`.
This matches the canonical target of the tested package's `/sbin/NetworkManager`.
Both running executables are now verified; the coordinated deployment and
stage 5 rollout audit are complete.

No live profiles, credential stores or IWD permissions are edited by this rollout.
Physical cold-boot/pre-login connectivity remains a separate operator check.
