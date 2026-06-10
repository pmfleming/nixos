[CmdletBinding(SupportsShouldProcess = $true)]
param(
  [Parameter(Mandatory = $true)]
  [string]$ImagePath,

  [string]$Name = "nixos-hyperv",
  [string]$SwitchName = "Default Switch",
  [string]$VmRoot = "$env:ProgramData\Microsoft\Windows\Hyper-V\VMs",

  [UInt64]$MemoryStartupBytes = 4GB,
  [UInt64]$MemoryMinimumBytes = 2GB,
  [UInt64]$MemoryMaximumBytes = 8GB,
  [UInt64]$DiskSizeBytes = 64GB,
  [int]$ProcessorCount = 4,

  [switch]$Start
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

function Assert-Administrator {
  $identity = [Security.Principal.WindowsIdentity]::GetCurrent()
  $principal = [Security.Principal.WindowsPrincipal]::new($identity)
  $adminRole = [Security.Principal.WindowsBuiltInRole]::Administrator

  if (-not $principal.IsInRole($adminRole)) {
    throw "Run this script from an elevated PowerShell session."
  }
}

function Resolve-VhdxImage {
  param([string]$Path)

  $item = Get-Item -LiteralPath $Path
  if ($item.PSIsContainer) {
    $image = Get-ChildItem -LiteralPath $item.FullName -Recurse -File |
      Where-Object { $_.Extension -in ".vhdx", ".vhd" } |
      Sort-Object FullName |
      Select-Object -First 1

    if (-not $image) {
      throw "No .vhdx or .vhd image was found under '$Path'."
    }

    return $image
  }

  if ($item.Extension -notin ".vhdx", ".vhd") {
    throw "ImagePath must point to a .vhdx/.vhd file or a directory containing one."
  }

  return $item
}

Assert-Administrator

if (-not (Get-Command New-VM -ErrorAction SilentlyContinue)) {
  throw "Hyper-V PowerShell cmdlets are not available. Enable Hyper-V first."
}

if (Get-VM -Name $Name -ErrorAction SilentlyContinue) {
  throw "A Hyper-V VM named '$Name' already exists."
}

$switch = Get-VMSwitch -Name $SwitchName -ErrorAction SilentlyContinue
if (-not $switch) {
  $available = (Get-VMSwitch | Select-Object -ExpandProperty Name) -join "', '"
  throw "Hyper-V switch '$SwitchName' was not found. Available switches: '$available'."
}

$sourceImage = Resolve-VhdxImage -Path $ImagePath
$vmPath = Join-Path $VmRoot $Name
$diskPath = Join-Path $vmPath "$Name.vhdx"

if ($PSCmdlet.ShouldProcess($Name, "Create Hyper-V VM from '$($sourceImage.FullName)'")) {
  New-Item -ItemType Directory -Path $vmPath -Force | Out-Null
  Copy-Item -LiteralPath $sourceImage.FullName -Destination $diskPath

  $vhd = Get-VHD -Path $diskPath
  if ($vhd.Size -lt $DiskSizeBytes) {
    Resize-VHD -Path $diskPath -SizeBytes $DiskSizeBytes
  }

  New-VM `
    -Name $Name `
    -Generation 2 `
    -MemoryStartupBytes $MemoryStartupBytes `
    -Path $vmPath `
    -SwitchName $SwitchName `
    -VHDPath $diskPath | Out-Null

  Set-VMProcessor -VMName $Name -Count $ProcessorCount
  Set-VMMemory `
    -VMName $Name `
    -DynamicMemoryEnabled $true `
    -MinimumBytes $MemoryMinimumBytes `
    -StartupBytes $MemoryStartupBytes `
    -MaximumBytes $MemoryMaximumBytes

  $drive = Get-VMHardDiskDrive -VMName $Name
  Set-VMFirmware -VMName $Name -EnableSecureBoot Off -FirstBootDevice $drive

  if ($Start) {
    Start-VM -Name $Name
  }

  Get-VM -Name $Name
}
