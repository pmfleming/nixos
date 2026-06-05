# NixOS Config

This repository tracks the NixOS configuration copied from `/etc/nixos`.

## Apply Changes

From this repository:

```sh
sudo nixos-rebuild switch -I nixos-config=$PWD/configuration.nix
```

## Sync From Live Config

If `/etc/nixos` is edited directly, copy the live files back before committing:

```sh
cp /etc/nixos/configuration.nix .
cp /etc/nixos/hardware-configuration.nix .
git diff
```

## Notes

- `hardware-configuration.nix` is machine-specific.
- Review `git diff` before pushing this repository to a remote.
