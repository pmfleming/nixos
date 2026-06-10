# NixOS Config

This repository tracks the live NixOS flake configuration in `/etc/nixos`.

## Apply Changes

Apply the ThinkPad configuration:

```sh
sudo nixos-rebuild switch --flake /etc/nixos#thinkpad
```

Apply the Hyper-V VM configuration:

```sh
sudo nixos-rebuild switch --flake /etc/nixos#hyperv
```

## Hyper-V VM

The `hyperv` host uses `hardware-hyperv.nix`, which expects:

- an ext4 root filesystem labeled `nixos`
- a FAT32 EFI system partition labeled `NIXBOOT`

During a manual install, create labels that match:

```sh
mkfs.ext4 -L nixos /dev/disk/by-id/<root-disk>
mkfs.fat -F 32 -n NIXBOOT /dev/disk/by-id/<efi-partition>
```

If the VM is installed with different labels or UUIDs, replace `hardware-hyperv.nix` in a local clone:

```sh
sudo nixos-generate-config --show-hardware-config > hardware-hyperv.nix
sudo nixos-rebuild switch --flake .#hyperv
```

## Validate Changes

Check the flake before applying it:

```sh
nix flake check /etc/nixos --no-build
```

## Notes

- `hardware-configuration.nix` is ThinkPad-specific.
- `hardware-hyperv.nix` is Hyper-V VM-specific.
- Review `git diff` before committing or applying changes.
