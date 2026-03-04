#Requires -RunAsAdministrator
<#
.SYNOPSIS
    Windows Guest OS Fingerprint Editor
    Change OS-level identifiers not covered by hypervisor (Proxmox VE) spoofing.

.DESCRIPTION
    This tool modifies Windows OS identifiers commonly used by browser fingerprinting.
    Since PVE (via pve-fingerprint.sh) handles MAC, BIOS, Board, Chassis, and CPU, this tool focuses on:
      - Machine GUID (Windows unique identifier)
      - Computer Name / Hostname
      - Windows Product ID
      - Disk Volume Serial Number (Partition Level)
      - GPU Adapter Name (Display)

.NOTES
    Author:  VM Fingerprint Tool (Guest OS Edition)
#>

$Script:LogFile = Join-Path $PSScriptRoot "guest-fingerprint-changes.log"
$Script:BackupFile = Join-Path $PSScriptRoot "guest-fingerprint-backup.json"

function Write-Log {
    param([string]$Message)
    $timestamp = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
    "$timestamp | $Message" | Out-File -Append -FilePath $Script:LogFile -Encoding UTF8
}

function Generate-RandomGUID { return [System.Guid]::NewGuid().ToString() }

function Generate-RandomSerial {
    param([int]$Length = 16)
    $chars = "ABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789"
    $serial = ""
    for ($i = 0; $i -lt $Length; $i++) { $serial += $chars[(Get-Random -Minimum 0 -Maximum $chars.Length)] }
    return $serial
}

function Generate-RandomComputerName {
    $prefixes = @("DESKTOP", "PC", "WIN", "WORKSTATION", "VM", "LAP")
    $prefix = $prefixes | Get-Random
    $suffix = Generate-RandomSerial -Length 7
    return "$prefix-$suffix"
}

function Generate-RandomProductId {
    $p1 = (Get-Random -Minimum 10000 -Maximum 99999).ToString()
    $p2 = (Get-Random -Minimum 100 -Maximum 999).ToString()
    $p3 = (Get-Random -Minimum 1000000 -Maximum 9999999).ToString()
    $p4 = (Get-Random -Minimum 10000 -Maximum 99999).ToString()
    return "$p1-$p2-$p3-$p4"
}

function Generate-RandomVolumeSerial {
    $p1 = '{0:X4}' -f (Get-Random -Minimum 0 -Maximum 65536)
    $p2 = '{0:X4}' -f (Get-Random -Minimum 0 -Maximum 65536)
    return "$p1-$p2"
}

function Show-Banner {
    Clear-Host
    $banner = @"
  ╔══════════════════════════════════════════════════════════════════╗
  ║        Windows Guest OS Fingerprint Editor v1.0                  ║
  ║        (Complement to PVE Hypervisor Spoofing)                   ║
  ╚══════════════════════════════════════════════════════════════════╝
"@
    Write-Host $banner -ForegroundColor Cyan
}

function Show-Separator { Write-Host "  ──────────────────────────────────────────────────────────────" -ForegroundColor DarkGray }

function Write-Status {
    param([string]$Label, [string]$Value, [string]$LabelColor = "Yellow", [string]$ValueColor = "White")
    Write-Host "  " -NoNewline
    Write-Host "$Label" -ForegroundColor $LabelColor -NoNewline
    Write-Host "$Value" -ForegroundColor $ValueColor
}

function Write-Success { param([string]$Message) Write-Host "  [OK] $Message" -ForegroundColor Green }
function Write-Err { param([string]$Message) Write-Host "  [!!] $Message" -ForegroundColor Red }
function Write-Warn { param([string]$Message) Write-Host "  [>>] $Message" -ForegroundColor Yellow }

function Backup-CurrentFingerprint {
    $backup = @{
        Timestamp     = (Get-Date -Format "yyyy-MM-dd HH:mm:ss")
        MachineGUID   = (Get-ItemProperty -Path "HKLM:\SOFTWARE\Microsoft\Cryptography" -Name MachineGuid -ErrorAction SilentlyContinue).MachineGuid
        ComputerName  = $env:COMPUTERNAME
        ProductID     = (Get-ItemProperty -Path "HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion" -Name ProductId -ErrorAction SilentlyContinue).ProductId
    }
    $backup | ConvertTo-Json | Out-File -FilePath $Script:BackupFile -Encoding UTF8
    Write-Success "Backup saved to: $Script:BackupFile"
    Write-Log "Backup created"
}

function Show-CurrentFingerprint {
    Show-Banner
    Write-Host "  CURRENT OS FINGERPRINT" -ForegroundColor Magenta
    Show-Separator
    Write-Host ""
    $machineGuid = (Get-ItemProperty -Path "HKLM:\SOFTWARE\Microsoft\Cryptography" -Name MachineGuid -ErrorAction SilentlyContinue).MachineGuid
    Write-Status "Machine GUID:    " $machineGuid
    Write-Status "Computer Name:   " $env:COMPUTERNAME
    $productId = (Get-ItemProperty -Path "HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion" -Name ProductId -ErrorAction SilentlyContinue).ProductId
    Write-Status "Product ID:      " $productId
    Write-Host ""
    
    Show-Separator
    Write-Host "  DISK VOLUMES" -ForegroundColor Magenta
    Show-Separator
    Write-Host ""
    $volumes = Get-WmiObject Win32_LogicalDisk -Filter "DriveType=3" -ErrorAction SilentlyContinue
    foreach ($vol in $volumes) {
        $serial = $vol.VolumeSerialNumber
        $label = if ($vol.VolumeName) { $vol.VolumeName } else { "(No Label)" }
        Write-Status "Drive $($vol.DeviceID)          " "$serial  [$label]"
    }
    Write-Host ""
    
    Show-Separator
    Write-Host "  GPU / DISPLAY" -ForegroundColor Magenta
    Show-Separator
    Write-Host ""
    $gpus = Get-WmiObject Win32_VideoController -ErrorAction SilentlyContinue
    foreach ($gpu in $gpus) {
        Write-Status "GPU:             " $gpu.Name
    }
    Write-Host ""
}

function Edit-MachineGUID {
    Show-Banner
    Write-Host "  CHANGE MACHINE GUID" -ForegroundColor Magenta
    Show-Separator
    Write-Host ""
    $currentGuid = (Get-ItemProperty -Path "HKLM:\SOFTWARE\Microsoft\Cryptography" -Name MachineGuid -ErrorAction SilentlyContinue).MachineGuid
    Write-Status "Current GUID:  " $currentGuid
    Write-Host ""
    $newGuid = Generate-RandomGUID
    try {
        Set-ItemProperty -Path "HKLM:\SOFTWARE\Microsoft\Cryptography" -Name MachineGuid -Value $newGuid -Force
        Write-Success "Machine GUID changed: $newGuid"
        Write-Log "Machine GUID changed: $currentGuid => $newGuid"
    } catch { Write-Err "Failed to change Machine GUID: $_" }
}

function Edit-ComputerName {
    Show-Banner
    Write-Host "  CHANGE COMPUTER NAME" -ForegroundColor Magenta
    Show-Separator
    Write-Host ""
    Write-Status "Current Name:  " $env:COMPUTERNAME
    Write-Host ""
    $newName = Generate-RandomComputerName
    try {
        Set-ItemProperty -Path "HKLM:\SYSTEM\CurrentControlSet\Control\ComputerName\ComputerName" -Name "ComputerName" -Value $newName -Force
        Set-ItemProperty -Path "HKLM:\SYSTEM\CurrentControlSet\Control\ComputerName\ActiveComputerName" -Name "ComputerName" -Value $newName -Force
        Set-ItemProperty -Path "HKLM:\SYSTEM\CurrentControlSet\Services\Tcpip\Parameters" -Name "Hostname" -Value $newName -Force
        Set-ItemProperty -Path "HKLM:\SYSTEM\CurrentControlSet\Services\Tcpip\Parameters" -Name "NV Hostname" -Value $newName -Force
        Write-Success "Computer name changed to: $newName"
        Write-Warn "Restart required."
        Write-Log "Computer name changed: $($env:COMPUTERNAME) => $newName"
    } catch { Write-Err "Failed to change computer name: $_" }
}

function Edit-ProductID {
    Show-Banner
    Write-Host "  CHANGE PRODUCT ID" -ForegroundColor Magenta
    Show-Separator
    Write-Host ""
    $currentId = (Get-ItemProperty -Path "HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion" -Name ProductId -ErrorAction SilentlyContinue).ProductId
    Write-Status "Current ID:    " $currentId
    Write-Host ""
    $newId = Generate-RandomProductId
    try {
        Set-ItemProperty -Path "HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion" -Name ProductId -Value $newId -Force
        Write-Success "Product ID changed to: $newId"
        Write-Log "Product ID changed: $currentId => $newId"
    } catch { Write-Err "Failed to change Product ID: $_" }
}

function Edit-VolumeSerial {
    Show-Banner
    Write-Host "  CHANGE VOLUME SERIAL" -ForegroundColor Magenta
    Show-Separator
    Write-Host ""
    $volumes = Get-WmiObject Win32_LogicalDisk -Filter "DriveType=3" -ErrorAction SilentlyContinue
    $spoofRegPath = "HKLM:\SOFTWARE\VMFingerprint\VolumeSerials"
    if (-not (Test-Path $spoofRegPath)) { New-Item -Path $spoofRegPath -Force | Out-Null }
    foreach ($vol in $volumes) {
        $newSerial = Generate-RandomVolumeSerial
        Set-ItemProperty -Path $spoofRegPath -Name $vol.DeviceID -Value $newSerial -Force
        Write-Success "$($vol.DeviceID)  =>  $newSerial"
    }
    Write-Host ""
    Write-Warn "Serials stored in registry."
    Write-Log "Volume serials updated"
}

function Edit-GPUName {
    Show-Banner
    Write-Host "  CHANGE GPU NAME" -ForegroundColor Magenta
    Show-Separator
    Write-Host ""
    $presets = @("NVIDIA GeForce RTX 4070", "NVIDIA GeForce RTX 3060", "AMD Radeon RX 7600", "Intel UHD Graphics 770")
    Write-Host "  Available Random Presets: $($presets -join ', ')" -ForegroundColor DarkGray
    Write-Host ""
    $selectedGPU = $presets | Get-Random
    $spoofRegPath = "HKLM:\SOFTWARE\VMFingerprint"
    if (-not (Test-Path $spoofRegPath)) { New-Item -Path $spoofRegPath -Force | Out-Null }
    Set-ItemProperty -Path $spoofRegPath -Name "GPUName" -Value $selectedGPU -Force
    
    $displayPath = "HKLM:\SYSTEM\CurrentControlSet\Control\Video"
    $subKeys = Get-ChildItem $displayPath -Recurse -ErrorAction SilentlyContinue | Where-Object { (Get-ItemProperty $_.PSPath -Name "DriverDesc" -ErrorAction SilentlyContinue) }
    foreach ($key in $subKeys) {
        Set-ItemProperty -Path $key.PSPath -Name "DriverDesc" -Value $selectedGPU -Force -ErrorAction SilentlyContinue
    }
    Write-Success "GPU name set to: $selectedGPU"
    Write-Log "GPU name spoofed: $selectedGPU"
}

function Randomize-AllFingerprints {
    Show-Banner
    Write-Host "  RANDOMIZE ALL OS FINGERPRINTS" -ForegroundColor Red
    Show-Separator
    Write-Host ""
    Backup-CurrentFingerprint
    Write-Host ""
    Edit-MachineGUID
    Edit-ComputerName
    Edit-ProductID
    Edit-VolumeSerial
    Edit-GPUName
    Write-Host ""
    Write-Success "All OS fingerprints randomized! Restart VM to apply changes."
}

function Show-MainMenu {
    Show-Banner
    Write-Host "  MAIN MENU" -ForegroundColor Magenta
    Show-Separator
    Write-Host ""
    Write-Host "    [1] View OS Fingerprint" -ForegroundColor White
    Write-Host ""
    Write-Host "    [2] Change Machine GUID" -ForegroundColor Yellow
    Write-Host "    [3] Change Computer Name" -ForegroundColor Yellow
    Write-Host "    [4] Change Product ID" -ForegroundColor Yellow
    Write-Host "    [5] Change Volume Serial" -ForegroundColor Yellow
    Write-Host "    [6] Change GPU Name" -ForegroundColor Yellow
    Write-Host ""
    Write-Host "    [R] Randomize All OS Fingerprints" -ForegroundColor Red
    Write-Host "    [0] Exit" -ForegroundColor DarkGray
    Write-Host ""
    Show-Separator
}

$isAdmin = ([Security.Principal.WindowsPrincipal] [Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
if (-not $isAdmin) {
    Write-Host ""
    Write-Host "  ERROR: This tool must be run as Administrator!" -ForegroundColor Red
    Write-Host ""
    exit 1
}

while ($true) {
    Show-MainMenu
    Write-Host ""
    $selection = Read-Host "  Enter choice"
    Write-Host ""
    switch ($selection) {
        "1" { Show-CurrentFingerprint; Read-Host "  Press Enter" }
        "2" { Edit-MachineGUID; Read-Host "  Press Enter" }
        "3" { Edit-ComputerName; Read-Host "  Press Enter" }
        "4" { Edit-ProductID; Read-Host "  Press Enter" }
        "5" { Edit-VolumeSerial; Read-Host "  Press Enter" }
        "6" { Edit-GPUName; Read-Host "  Press Enter" }
        "R" { Randomize-AllFingerprints; Read-Host "  Press Enter" }
        "r" { Randomize-AllFingerprints; Read-Host "  Press Enter" }
        "0" { exit 0 }
        default { Write-Warn "Invalid option." ; Start-Sleep -Seconds 1 }
    }
}
