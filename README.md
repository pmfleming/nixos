# NixOS Config

This repository tracks the live NixOS flake configuration in `/etc/nixos`.

## Apply Changes

Daily ThinkPad rebuild:

```sh
rebuild
```

Equivalent explicit command:

```sh
sudo nixos-rebuild switch --flake /etc/nixos#thinkpad
```

Home Manager is integrated as a NixOS module, so home changes in `home.nix` are applied by the same rebuild.

## Validate Changes

Check the flake before applying it:

```sh
nix flake check /etc/nixos --no-build
```

## Automatic Updates

`delayed-nixos-update.service` checks for flake input updates and applies most of them after they have remained available for 3 days. `nixpkgs-unstable` updates immediately so Codex, Pi, and Claude stay on the latest unstable build. It updates `/etc/nixos/flake.lock` directly, so the git tree may become dirty after an automatic update. Review and commit that lock-file change intentionally.

## Notes

- `hardware-configuration.nix` is machine-specific.
- Review `git diff` before committing or applying changes.
