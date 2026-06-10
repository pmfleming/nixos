# NixOS Config

This repository tracks the live NixOS flake configuration in `/etc/nixos`.

## Layout

- `configuration.nix` imports the shared NixOS modules.
- `modules/nixos/` contains shared system configuration used by both hosts.
- `hosts/` contains host-specific policy layered on top of the shared modules.
- `hardware-configuration.nix` is ThinkPad-specific hardware configuration.
- `hardware-hyperv.nix` is Hyper-V-specific hardware configuration.
- `home.nix` contains the Home Manager user configuration.

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
- a FAT32 EFI system partition labeled `ESP`

During a manual install, create labels that match:

```sh
mkfs.ext4 -L nixos /dev/disk/by-id/<root-disk>
mkfs.fat -F 32 -n ESP /dev/disk/by-id/<efi-partition>
```

If the VM is installed with different labels or UUIDs, replace `hardware-hyperv.nix` in a local clone:

```sh
sudo nixos-generate-config --show-hardware-config > hardware-hyperv.nix
sudo nixos-rebuild switch --flake .#hyperv
```

## Build a Hyper-V Image

On Windows, this checkout lives at `C:\Users\Paul_\nixos`. The `/etc/nixos`
path is only for a running NixOS system; it is not a folder inside this Windows
checkout.

Build a bootable Hyper-V VHDX from the `hyperv` host configuration on a NixOS
machine. If the repository is checked out somewhere other than `/etc/nixos`,
`cd` into that checkout and use `.#hyperv-vhdx`:

```sh
cd /path/to/nixos
nix build .#hyperv-vhdx
```

If this repository is the live NixOS config at `/etc/nixos`, this is equivalent:

```sh
nix build /etc/nixos#hyperv-vhdx
```

Or build the same image directly through `nixos-rebuild`:

```sh
sudo nixos-rebuild build-image --image-variant hyperv --flake /etc/nixos#hyperv
```

Copy the produced VHDX to Windows. If this repository is also checked out at
`C:\Users\Paul_\nixos`, this works from WSL/NixOS with Windows drives mounted:

```sh
cp -L result/*.vhdx /mnt/c/Users/Paul_/nixos/nixos-hyperv.vhdx
```

Then import it into Hyper-V from an elevated PowerShell session on Windows:

```powershell
.\scripts\New-NixOSHyperVVm.ps1 -ImagePath .\nixos-hyperv.vhdx -Start
```

The importer creates a Generation 2 VM named `nixos-hyperv`, disables Secure
Boot, attaches the default Hyper-V switch, expands the disk to 64 GiB, and boots
the VHDX.

The generated image includes this flake at `/etc/nixos`. Log in as `laufan` with
the initial password `nixos`, then change it:

```sh
passwd
```

The basic Hyper-V console does not dynamically resize Linux guests when the
VMConnect window enters fullscreen. The `hyperv` profile sets the guest
framebuffer to 1920x1080 with `video=hyperv_fb:1920x1080`; change that kernel
parameter in `hardware-hyperv.nix` if you want a different fixed resolution.

## Validate Changes

Check the flake before applying it:

```sh
nix flake check /etc/nixos --no-build
```

## Notes

- `hardware-configuration.nix` is ThinkPad-specific.
- `hardware-hyperv.nix` is Hyper-V VM-specific.
- Review `git diff` before committing or applying changes.
