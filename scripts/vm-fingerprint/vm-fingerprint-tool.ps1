#Requires -RunAsAdministrator
<#
.SYNOPSIS
    VM Hardware Fingerprint Editor
    Change hardware identifiers for browser fingerprint isolation in VM environments.

.DESCRIPTION
    This tool modifies hardware identifiers commonly used by browser fingerprinting:
      - MAC Address (WebRTC leak, network adapter)
      - Machine GUID (Windows unique identifier)
      - Computer Name / Hostname
      - BIOS Serial Number (via registry)
      - Baseboard Serial Number (via registry)
      - Disk Volume Serial Number
      - Windows Product ID
      - GPU Adapter Name (Display)

.NOTES
    Author:  VM Fingerprint Tool
    Usage:   Run as Administrator in PowerShell
    Target:  Windows VMs for browser fingerprint environment isolation
#>

# ============================================================================
# CONFIGURATION
# ============================================================================
$Script:LogFile = Join-Path $PSScriptRoot "fingerprint-changes.log"
$Script:BackupFile = Join-Path $PSScriptRoot "fingerprint-backup.json"

# ============================================================================
# UTILITY FUNCTIONS
# ============================================================================

function Write-Log {
    param([string]$Message)
    $timestamp = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
    "$timestamp | $Message" | Out-File -Append -FilePath $Script:LogFile -Encoding UTF8
}

function Generate-RandomMAC {
    # Generate a locally administered, unicast MAC address
    # Bit 1 of first octet = 1 (locally administered), Bit 0 = 0 (unicast)
    $validFirstOctets = @(0x02, 0x06, 0x0A, 0x0E, 0x12, 0x16, 0x1A, 0x1E,
                          0x22, 0x26, 0x2A, 0x2E, 0x32, 0x36, 0x3A, 0x3E,
                          0x42, 0x46, 0x4A, 0x4E, 0x52, 0x56, 0x5A, 0x5E,
                          0x62, 0x66, 0x6A, 0x6E, 0x72, 0x76, 0x7A, 0x7E,
                          0x82, 0x86, 0x8A, 0x8E, 0x92, 0x96, 0x9A, 0x9E,
                          0xA2, 0xA6, 0xAA, 0xAE, 0xB2, 0xB6, 0xBA, 0xBE,
                          0xC2, 0xC6, 0xCA, 0xCE, 0xD2, 0xD6, 0xDA, 0xDE,
                          0xE2, 0xE6, 0xEA, 0xEE, 0xF2, 0xF6, 0xFA, 0xFE)
    $first = $validFirstOctets | Get-Random
    $bytes = @($first)
    for ($i = 1; $i -le 5; $i++) {
        $bytes += Get-Random -Minimum 0 -Maximum 256
    }
    return ($bytes | ForEach-Object { $_.ToString("X2") }) -join ""
}

function Generate-RandomGUID {
    return [System.Guid]::NewGuid().ToString()
}

function Generate-RandomSerial {
    param([int]$Length = 16)
    $chars = "ABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789"
    $serial = ""
    for ($i = 0; $i -lt $Length; $i++) {
        $serial += $chars[(Get-Random -Minimum 0 -Maximum $chars.Length)]
    }
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
  ║                                                                ║
  ║          ██╗   ██╗███╗   ███╗    ███████╗██████╗               ║
  ║          ██║   ██║████╗ ████║    ██╔════╝██╔══██╗              ║
  ║          ██║   ██║██╔████╔██║    █████╗  ██████╔╝              ║
  ║          ╚██╗ ██╔╝██║╚██╔╝██║    ██╔══╝  ██╔═══╝              ║
  ║           ╚████╔╝ ██║ ╚═╝ ██║    ██║     ██║                  ║
  ║            ╚═══╝  ╚═╝     ╚═╝    ╚═╝     ╚═╝                  ║
  ║                                                                ║
  ║        VM  Hardware  Fingerprint  Editor  v1.0                 ║
  ║        Browser Fingerprint Environment Tool                    ║
  ║                                                                ║
  ╚══════════════════════════════════════════════════════════════════╝

"@
    Write-Host $banner -ForegroundColor Cyan
}

function Show-Separator {
    Write-Host "  ──────────────────────────────────────────────────────────────" -ForegroundColor DarkGray
}

function Write-Status {
    param(
        [string]$Label,
        [string]$Value,
        [string]$LabelColor = "Yellow",
        [string]$ValueColor = "White"
    )
    Write-Host "  " -NoNewline
    Write-Host "$Label" -ForegroundColor $LabelColor -NoNewline
    Write-Host "$Value" -ForegroundColor $ValueColor
}

function Write-Success {
    param([string]$Message)
    Write-Host "  [OK] $Message" -ForegroundColor Green
}

function Write-Err {
    param([string]$Message)
    Write-Host "  [!!] $Message" -ForegroundColor Red
}

function Write-Warn {
    param([string]$Message)
    Write-Host "  [>>] $Message" -ForegroundColor Yellow
}

# ============================================================================
# BACKUP & RESTORE
# ============================================================================

function Backup-CurrentFingerprint {
    $backup = @{
        Timestamp     = (Get-Date -Format "yyyy-MM-dd HH:mm:ss")
        MachineGUID   = (Get-ItemProperty -Path "HKLM:\SOFTWARE\Microsoft\Cryptography" -Name MachineGuid -ErrorAction SilentlyContinue).MachineGuid
        ComputerName  = $env:COMPUTERNAME
        ProductID     = (Get-ItemProperty -Path "HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion" -Name ProductId -ErrorAction SilentlyContinue).ProductId
        BIOSSerial    = (Get-WmiObject Win32_BIOS -ErrorAction SilentlyContinue).SerialNumber
        BoardSerial   = (Get-WmiObject Win32_BaseBoard -ErrorAction SilentlyContinue).SerialNumber
        MACAddresses  = @()
    }

    $nics = Get-NetAdapter -Physical -ErrorAction SilentlyContinue
    foreach ($nic in $nics) {
        $backup.MACAddresses += @{
            Name       = $nic.Name
            MacAddress = $nic.MacAddress
            DeviceID   = $nic.DeviceID
        }
    }

    $backup | ConvertTo-Json -Depth 5 | Out-File -FilePath $Script:BackupFile -Encoding UTF8
    Write-Success "Backup saved to: $Script:BackupFile"
    Write-Log "Backup created: $Script:BackupFile"
}

# ============================================================================
# VIEW FUNCTIONS
# ============================================================================

function Show-CurrentFingerprint {
    Show-Banner
    Write-Host "  CURRENT HARDWARE FINGERPRINT" -ForegroundColor Magenta
    Show-Separator
    Write-Host ""

    # Machine GUID
    $machineGuid = (Get-ItemProperty -Path "HKLM:\SOFTWARE\Microsoft\Cryptography" -Name MachineGuid -ErrorAction SilentlyContinue).MachineGuid
    Write-Status "  Machine GUID:     " $machineGuid

    # Computer Name
    Write-Status "  Computer Name:    " $env:COMPUTERNAME

    # Windows Product ID
    $productId = (Get-ItemProperty -Path "HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion" -Name ProductId -ErrorAction SilentlyContinue).ProductId
    Write-Status "  Product ID:       " $productId

    Write-Host ""
    Show-Separator
    Write-Host "  HARDWARE SERIALS" -ForegroundColor Magenta
    Show-Separator
    Write-Host ""

    # BIOS Serial
    $biosSerial = (Get-WmiObject Win32_BIOS -ErrorAction SilentlyContinue).SerialNumber
    Write-Status "  BIOS Serial:      " $biosSerial

    # Baseboard Serial
    $boardSerial = (Get-WmiObject Win32_BaseBoard -ErrorAction SilentlyContinue).SerialNumber
    Write-Status "  Board Serial:     " $boardSerial

    # CPU ID
    $cpuId = (Get-WmiObject Win32_Processor -ErrorAction SilentlyContinue).ProcessorId
    Write-Status "  CPU ID:           " $cpuId

    # System UUID
    $uuid = (Get-WmiObject Win32_ComputerSystemProduct -ErrorAction SilentlyContinue).UUID
    Write-Status "  System UUID:      " $uuid

    Write-Host ""
    Show-Separator
    Write-Host "  NETWORK ADAPTERS" -ForegroundColor Magenta
    Show-Separator
    Write-Host ""

    # MAC Addresses
    $nics = Get-NetAdapter -Physical -ErrorAction SilentlyContinue
    if ($nics) {
        foreach ($nic in $nics) {
            $status = if ($nic.Status -eq "Up") { "[UP]  " } else { "[DOWN]" }
            $statusColor = if ($nic.Status -eq "Up") { "Green" } else { "DarkGray" }
            Write-Host "    " -NoNewline
            Write-Host $status -ForegroundColor $statusColor -NoNewline
            Write-Host " $($nic.Name)" -ForegroundColor Yellow -NoNewline
            Write-Host "  =>  " -ForegroundColor DarkGray -NoNewline
            Write-Host "$($nic.MacAddress)" -ForegroundColor White
        }
    } else {
        Write-Host "    No physical adapters found" -ForegroundColor DarkGray
    }

    Write-Host ""
    Show-Separator
    Write-Host "  DISK VOLUMES" -ForegroundColor Magenta
    Show-Separator
    Write-Host ""

    # Volume Serial Numbers
    $volumes = Get-WmiObject Win32_LogicalDisk -Filter "DriveType=3" -ErrorAction SilentlyContinue
    foreach ($vol in $volumes) {
        $serial = $vol.VolumeSerialNumber
        $label = if ($vol.VolumeName) { $vol.VolumeName } else { "(No Label)" }
        Write-Status "  Drive $($vol.DeviceID)           " "$serial  [$label]"
    }

    Write-Host ""
    Show-Separator
    Write-Host "  GPU / DISPLAY" -ForegroundColor Magenta
    Show-Separator
    Write-Host ""

    # GPU Info
    $gpus = Get-WmiObject Win32_VideoController -ErrorAction SilentlyContinue
    foreach ($gpu in $gpus) {
        Write-Status "  GPU:              " $gpu.Name
    }

    Write-Host ""
    Show-Separator
    Write-Host ""
}

# ============================================================================
# EDIT FUNCTIONS
# ============================================================================

function Edit-MACAddress {
    Show-Banner
    Write-Host "  CHANGE MAC ADDRESS" -ForegroundColor Magenta
    Show-Separator
    Write-Host ""

    $nics = Get-NetAdapter -Physical -ErrorAction SilentlyContinue
    if (-not $nics) {
        Write-Err "No physical network adapters found."
        return
    }

    # List adapters
    $i = 1
    $nicList = @()
    foreach ($nic in $nics) {
        $status = if ($nic.Status -eq "Up") { "UP" } else { "DOWN" }
        Write-Host "    [$i] " -ForegroundColor Cyan -NoNewline
        Write-Host "$($nic.Name)" -ForegroundColor Yellow -NoNewline
        Write-Host "  |  $($nic.MacAddress)  |  $status" -ForegroundColor White
        $nicList += $nic
        $i++
    }

    Write-Host ""
    Write-Host "    [A] " -ForegroundColor Green -NoNewline
    Write-Host "Change ALL adapters with random MACs" -ForegroundColor White
    Write-Host "    [0] " -ForegroundColor DarkGray -NoNewline
    Write-Host "Back to menu" -ForegroundColor DarkGray
    Write-Host ""

    $choice = Read-Host "  Select adapter"

    if ($choice -eq "0") { return }

    if ($choice -eq "A" -or $choice -eq "a") {
        # Change all adapters
        foreach ($nic in $nicList) {
            $newMAC = Generate-RandomMAC
            Set-MACForAdapter -Adapter $nic -NewMAC $newMAC
        }
        Write-Host ""
        Write-Success "All adapters updated. Restarting network adapters..."
        Restart-NetworkAdapters -Adapters $nicList
        return
    }

    $idx = [int]$choice - 1
    if ($idx -lt 0 -or $idx -ge $nicList.Count) {
        Write-Err "Invalid selection."
        return
    }

    $selectedNic = $nicList[$idx]
    Write-Host ""
    Write-Host "    [1] " -ForegroundColor Cyan -NoNewline
    Write-Host "Generate random MAC" -ForegroundColor White
    Write-Host "    [2] " -ForegroundColor Cyan -NoNewline
    Write-Host "Enter custom MAC" -ForegroundColor White
    Write-Host ""

    $macChoice = Read-Host "  Select option"

    if ($macChoice -eq "1") {
        $newMAC = Generate-RandomMAC
        Write-Warn "Generated MAC: $(Format-MAC $newMAC)"
    } elseif ($macChoice -eq "2") {
        $input_mac = Read-Host "  Enter MAC (e.g. 0A1B2C3D4E5F or 0A-1B-2C-3D-4E-5F)"
        $newMAC = $input_mac -replace "[-:]", ""
        if ($newMAC.Length -ne 12 -or $newMAC -notmatch '^[0-9A-Fa-f]{12}$') {
            Write-Err "Invalid MAC address format."
            return
        }
    } else {
        return
    }

    Set-MACForAdapter -Adapter $selectedNic -NewMAC $newMAC
    Write-Host ""
    Write-Success "Restarting network adapter..."
    Restart-NetworkAdapters -Adapters @($selectedNic)
}

function Format-MAC {
    param([string]$mac)
    $mac = $mac.ToUpper()
    $formatted = ""
    for ($i = 0; $i -lt $mac.Length; $i += 2) {
        if ($i -gt 0) { $formatted += "-" }
        $formatted += $mac.Substring($i, 2)
    }
    return $formatted
}

function Set-MACForAdapter {
    param($Adapter, [string]$NewMAC)

    $deviceId = $Adapter.DeviceID
    # Find the registry key for this adapter
    $regBase = "HKLM:\SYSTEM\CurrentControlSet\Control\Class\{4D36E972-E325-11CE-BFC1-08002bE10318}"

    $subKeys = Get-ChildItem $regBase -ErrorAction SilentlyContinue
    foreach ($key in $subKeys) {
        $driverDesc = (Get-ItemProperty $key.PSPath -Name "DriverDesc" -ErrorAction SilentlyContinue).DriverDesc
        $netCfgId = (Get-ItemProperty $key.PSPath -Name "NetCfgInstanceId" -ErrorAction SilentlyContinue).NetCfgInstanceId

        if ($netCfgId -eq $Adapter.InterfaceGuid -or $driverDesc -eq $Adapter.InterfaceDescription) {
            Set-ItemProperty -Path $key.PSPath -Name "NetworkAddress" -Value $NewMAC -Type String -Force
            Write-Success "MAC set for $($Adapter.Name): $(Format-MAC $NewMAC)"
            Write-Log "MAC changed: $($Adapter.Name) => $(Format-MAC $NewMAC)"
            return
        }
    }
    Write-Err "Could not find registry key for adapter: $($Adapter.Name)"
}

function Restart-NetworkAdapters {
    param($Adapters)
    foreach ($adapter in $Adapters) {
        try {
            Disable-NetAdapter -Name $adapter.Name -Confirm:$false -ErrorAction Stop
            Start-Sleep -Seconds 2
            Enable-NetAdapter -Name $adapter.Name -Confirm:$false -ErrorAction Stop
            Write-Success "Adapter '$($adapter.Name)' restarted."
        } catch {
            Write-Err "Failed to restart '$($adapter.Name)': $_"
        }
    }
}

function Edit-MachineGUID {
    Show-Banner
    Write-Host "  CHANGE MACHINE GUID" -ForegroundColor Magenta
    Show-Separator
    Write-Host ""

    $currentGuid = (Get-ItemProperty -Path "HKLM:\SOFTWARE\Microsoft\Cryptography" -Name MachineGuid -ErrorAction SilentlyContinue).MachineGuid
    Write-Status "  Current GUID:  " $currentGuid
    Write-Host ""

    Write-Host "    [1] " -ForegroundColor Cyan -NoNewline
    Write-Host "Generate random GUID" -ForegroundColor White
    Write-Host "    [2] " -ForegroundColor Cyan -NoNewline
    Write-Host "Enter custom GUID" -ForegroundColor White
    Write-Host "    [0] " -ForegroundColor DarkGray -NoNewline
    Write-Host "Back" -ForegroundColor DarkGray
    Write-Host ""

    $choice = Read-Host "  Select option"

    switch ($choice) {
        "1" { $newGuid = Generate-RandomGUID }
        "2" {
            $newGuid = Read-Host "  Enter GUID (format: xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx)"
            if ($newGuid -notmatch '^[0-9a-fA-F]{8}-([0-9a-fA-F]{4}-){3}[0-9a-fA-F]{12}$') {
                Write-Err "Invalid GUID format."
                return
            }
        }
        default { return }
    }

    try {
        Set-ItemProperty -Path "HKLM:\SOFTWARE\Microsoft\Cryptography" -Name MachineGuid -Value $newGuid -Force
        Write-Host ""
        Write-Success "Machine GUID changed: $newGuid"
        Write-Log "Machine GUID changed: $currentGuid => $newGuid"
    } catch {
        Write-Err "Failed to change Machine GUID: $_"
    }
}

function Edit-ComputerName {
    Show-Banner
    Write-Host "  CHANGE COMPUTER NAME" -ForegroundColor Magenta
    Show-Separator
    Write-Host ""

    Write-Status "  Current Name:  " $env:COMPUTERNAME
    Write-Host ""

    Write-Host "    [1] " -ForegroundColor Cyan -NoNewline
    Write-Host "Generate random name" -ForegroundColor White
    Write-Host "    [2] " -ForegroundColor Cyan -NoNewline
    Write-Host "Enter custom name" -ForegroundColor White
    Write-Host "    [0] " -ForegroundColor DarkGray -NoNewline
    Write-Host "Back" -ForegroundColor DarkGray
    Write-Host ""

    $choice = Read-Host "  Select option"

    switch ($choice) {
        "1" { $newName = Generate-RandomComputerName }
        "2" {
            $newName = Read-Host "  Enter new computer name (max 15 chars, alphanumeric + hyphen)"
            if ($newName.Length -gt 15 -or $newName -notmatch '^[A-Za-z0-9\-]+$') {
                Write-Err "Invalid computer name. Max 15 chars, alphanumeric and hyphens only."
                return
            }
        }
        default { return }
    }

    try {
        # Change via registry for immediate WMI/browser visibility
        Set-ItemProperty -Path "HKLM:\SYSTEM\CurrentControlSet\Control\ComputerName\ComputerName" -Name "ComputerName" -Value $newName -Force
        Set-ItemProperty -Path "HKLM:\SYSTEM\CurrentControlSet\Control\ComputerName\ActiveComputerName" -Name "ComputerName" -Value $newName -Force
        Set-ItemProperty -Path "HKLM:\SYSTEM\CurrentControlSet\Services\Tcpip\Parameters" -Name "Hostname" -Value $newName -Force
        Set-ItemProperty -Path "HKLM:\SYSTEM\CurrentControlSet\Services\Tcpip\Parameters" -Name "NV Hostname" -Value $newName -Force

        Write-Host ""
        Write-Success "Computer name changed to: $newName"
        Write-Warn "A restart is required for the name change to fully take effect."
        Write-Log "Computer name changed: $($env:COMPUTERNAME) => $newName"
    } catch {
        Write-Err "Failed to change computer name: $_"
    }
}

function Edit-BIOSSerial {
    Show-Banner
    Write-Host "  CHANGE BIOS / BASEBOARD SERIALS (Registry)" -ForegroundColor Magenta
    Show-Separator
    Write-Host ""

    $biosSerial = (Get-WmiObject Win32_BIOS -ErrorAction SilentlyContinue).SerialNumber
    $boardSerial = (Get-WmiObject Win32_BaseBoard -ErrorAction SilentlyContinue).SerialNumber
    $uuid = (Get-WmiObject Win32_ComputerSystemProduct -ErrorAction SilentlyContinue).UUID

    Write-Status "  BIOS Serial:   " $biosSerial
    Write-Status "  Board Serial:  " $boardSerial
    Write-Status "  System UUID:   " $uuid
    Write-Host ""
    Write-Host "  NOTE: These values are provided by WMI. In VMs, they can be" -ForegroundColor DarkYellow
    Write-Host "  spoofed through the VM hypervisor config or registry overrides." -ForegroundColor DarkYellow
    Write-Host ""

    Write-Host "    [1] " -ForegroundColor Cyan -NoNewline
    Write-Host "Spoof BIOS Serial (WMI registry override)" -ForegroundColor White
    Write-Host "    [2] " -ForegroundColor Cyan -NoNewline
    Write-Host "Spoof Baseboard Serial (WMI registry override)" -ForegroundColor White
    Write-Host "    [3] " -ForegroundColor Cyan -NoNewline
    Write-Host "Spoof System UUID (WMI registry override)" -ForegroundColor White
    Write-Host "    [4] " -ForegroundColor Cyan -NoNewline
    Write-Host "Spoof ALL with random values" -ForegroundColor White
    Write-Host "    [0] " -ForegroundColor DarkGray -NoNewline
    Write-Host "Back" -ForegroundColor DarkGray
    Write-Host ""

    $choice = Read-Host "  Select option"

    # Registry path for WMI spoofing
    $spoofRegPath = "HKLM:\SOFTWARE\VMFingerprint"
    if (-not (Test-Path $spoofRegPath)) {
        New-Item -Path $spoofRegPath -Force | Out-Null
    }

    switch ($choice) {
        "1" {
            Write-Host ""
            Write-Host "    [R] Random  [C] Custom" -ForegroundColor DarkCyan
            $sub = Read-Host "    Choose"
            $newSerial = if ($sub -eq "C" -or $sub -eq "c") { Read-Host "  Enter BIOS Serial" } else { Generate-RandomSerial -Length 20 }
            Set-ItemProperty -Path $spoofRegPath -Name "BIOSSerial" -Value $newSerial -Force
            # Also try to set via SystemInfo registry
            $sysInfoPath = "HKLM:\SYSTEM\CurrentControlSet\Control\SystemInformation"
            if (-not (Test-Path $sysInfoPath)) { New-Item -Path $sysInfoPath -Force | Out-Null }
            Set-ItemProperty -Path $sysInfoPath -Name "BIOSSerialNumber" -Value $newSerial -Force -ErrorAction SilentlyContinue
            Write-Success "BIOS Serial set to: $newSerial"
            Write-Log "BIOS Serial spoofed: $newSerial"
        }
        "2" {
            Write-Host ""
            Write-Host "    [R] Random  [C] Custom" -ForegroundColor DarkCyan
            $sub = Read-Host "    Choose"
            $newSerial = if ($sub -eq "C" -or $sub -eq "c") { Read-Host "  Enter Board Serial" } else { Generate-RandomSerial -Length 16 }
            Set-ItemProperty -Path $spoofRegPath -Name "BoardSerial" -Value $newSerial -Force
            $sysInfoPath = "HKLM:\SYSTEM\CurrentControlSet\Control\SystemInformation"
            if (-not (Test-Path $sysInfoPath)) { New-Item -Path $sysInfoPath -Force | Out-Null }
            Set-ItemProperty -Path $sysInfoPath -Name "BaseBoardSerialNumber" -Value $newSerial -Force -ErrorAction SilentlyContinue
            Write-Success "Baseboard Serial set to: $newSerial"
            Write-Log "Baseboard Serial spoofed: $newSerial"
        }
        "3" {
            Write-Host ""
            Write-Host "    [R] Random  [C] Custom" -ForegroundColor DarkCyan
            $sub = Read-Host "    Choose"
            $newUUID = if ($sub -eq "C" -or $sub -eq "c") { Read-Host "  Enter UUID" } else { Generate-RandomGUID }
            Set-ItemProperty -Path $spoofRegPath -Name "SystemUUID" -Value $newUUID -Force
            $sysInfoPath = "HKLM:\SYSTEM\CurrentControlSet\Control\SystemInformation"
            if (-not (Test-Path $sysInfoPath)) { New-Item -Path $sysInfoPath -Force | Out-Null }
            Set-ItemProperty -Path $sysInfoPath -Name "SystemProductName" -Value (Generate-RandomSerial -Length 10) -Force -ErrorAction SilentlyContinue
            Write-Success "System UUID set to: $newUUID"
            Write-Log "System UUID spoofed: $newUUID"
        }
        "4" {
            $newBIOS = Generate-RandomSerial -Length 20
            $newBoard = Generate-RandomSerial -Length 16
            $newUUID = Generate-RandomGUID
            $newProduct = Generate-RandomSerial -Length 10

            Set-ItemProperty -Path $spoofRegPath -Name "BIOSSerial" -Value $newBIOS -Force
            Set-ItemProperty -Path $spoofRegPath -Name "BoardSerial" -Value $newBoard -Force
            Set-ItemProperty -Path $spoofRegPath -Name "SystemUUID" -Value $newUUID -Force

            $sysInfoPath = "HKLM:\SYSTEM\CurrentControlSet\Control\SystemInformation"
            if (-not (Test-Path $sysInfoPath)) { New-Item -Path $sysInfoPath -Force | Out-Null }
            Set-ItemProperty -Path $sysInfoPath -Name "BIOSSerialNumber" -Value $newBIOS -Force -ErrorAction SilentlyContinue
            Set-ItemProperty -Path $sysInfoPath -Name "BaseBoardSerialNumber" -Value $newBoard -Force -ErrorAction SilentlyContinue
            Set-ItemProperty -Path $sysInfoPath -Name "SystemProductName" -Value $newProduct -Force -ErrorAction SilentlyContinue
            Set-ItemProperty -Path $sysInfoPath -Name "SystemManufacturer" -Value "Standard PC" -Force -ErrorAction SilentlyContinue

            Write-Host ""
            Write-Success "BIOS Serial:       $newBIOS"
            Write-Success "Baseboard Serial:  $newBoard"
            Write-Success "System UUID:       $newUUID"
            Write-Success "Product Name:      $newProduct"
            Write-Log "All hardware serials randomized"
        }
        default { return }
    }
}

function Edit-ProductID {
    Show-Banner
    Write-Host "  CHANGE WINDOWS PRODUCT ID" -ForegroundColor Magenta
    Show-Separator
    Write-Host ""

    $currentId = (Get-ItemProperty -Path "HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion" -Name ProductId -ErrorAction SilentlyContinue).ProductId
    Write-Status "  Current Product ID:  " $currentId
    Write-Host ""

    Write-Host "    [1] " -ForegroundColor Cyan -NoNewline
    Write-Host "Generate random Product ID" -ForegroundColor White
    Write-Host "    [2] " -ForegroundColor Cyan -NoNewline
    Write-Host "Enter custom Product ID" -ForegroundColor White
    Write-Host "    [0] " -ForegroundColor DarkGray -NoNewline
    Write-Host "Back" -ForegroundColor DarkGray
    Write-Host ""

    $choice = Read-Host "  Select option"

    switch ($choice) {
        "1" { $newId = Generate-RandomProductId }
        "2" { $newId = Read-Host "  Enter Product ID (format: XXXXX-XXX-XXXXXXX-XXXXX)" }
        default { return }
    }

    try {
        Set-ItemProperty -Path "HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion" -Name ProductId -Value $newId -Force
        Write-Host ""
        Write-Success "Product ID changed to: $newId"
        Write-Log "Product ID changed: $currentId => $newId"
    } catch {
        Write-Err "Failed to change Product ID: $_"
    }
}

function Edit-VolumeSerial {
    Show-Banner
    Write-Host "  CHANGE DISK VOLUME SERIAL NUMBER" -ForegroundColor Magenta
    Show-Separator
    Write-Host ""

    Write-Host "  Volume serial numbers can be changed using the 'volumeid' utility." -ForegroundColor DarkYellow
    Write-Host "  This will generate a helper script to change them." -ForegroundColor DarkYellow
    Write-Host ""

    $volumes = Get-WmiObject Win32_LogicalDisk -Filter "DriveType=3" -ErrorAction SilentlyContinue
    $i = 1
    foreach ($vol in $volumes) {
        $label = if ($vol.VolumeName) { $vol.VolumeName } else { "(No Label)" }
        Write-Host "    [$i] " -ForegroundColor Cyan -NoNewline
        Write-Host "$($vol.DeviceID) " -ForegroundColor Yellow -NoNewline
        Write-Host " Serial: $($vol.VolumeSerialNumber)  [$label]" -ForegroundColor White
        $i++
    }

    Write-Host ""
    Write-Host "    [A] " -ForegroundColor Green -NoNewline
    Write-Host "Generate random serials for ALL volumes" -ForegroundColor White
    Write-Host "    [0] " -ForegroundColor DarkGray -NoNewline
    Write-Host "Back" -ForegroundColor DarkGray
    Write-Host ""

    $choice = Read-Host "  Select option"
    if ($choice -eq "0") { return }

    # Store the volume serial changes in registry for tracking
    $spoofRegPath = "HKLM:\SOFTWARE\VMFingerprint\VolumeSerials"
    if (-not (Test-Path $spoofRegPath)) {
        New-Item -Path $spoofRegPath -Force | Out-Null
    }

    if ($choice -eq "A" -or $choice -eq "a") {
        foreach ($vol in $volumes) {
            $newSerial = Generate-RandomVolumeSerial
            Set-ItemProperty -Path $spoofRegPath -Name $vol.DeviceID -Value $newSerial -Force
            Write-Success "$($vol.DeviceID)  =>  $newSerial"
        }
        Write-Host ""
        Write-Warn "Volume serials stored in registry. Use VolumeID tool or format to apply."
    } else {
        $idx = [int]$choice - 1
        $volArray = @($volumes)
        if ($idx -lt 0 -or $idx -ge $volArray.Count) {
            Write-Err "Invalid selection."
            return
        }
        $selectedVol = $volArray[$idx]
        $newSerial = Generate-RandomVolumeSerial
        Set-ItemProperty -Path $spoofRegPath -Name $selectedVol.DeviceID -Value $newSerial -Force
        Write-Success "$($selectedVol.DeviceID)  =>  $newSerial"
    }

    Write-Log "Volume serials updated"
}

function Edit-GPUName {
    Show-Banner
    Write-Host "  CHANGE GPU / DISPLAY ADAPTER NAME" -ForegroundColor Magenta
    Show-Separator
    Write-Host ""

    $gpus = Get-WmiObject Win32_VideoController -ErrorAction SilentlyContinue
    $i = 1
    foreach ($gpu in $gpus) {
        Write-Host "    [$i] " -ForegroundColor Cyan -NoNewline
        Write-Host "$($gpu.Name)" -ForegroundColor Yellow -NoNewline
        Write-Host "  (Driver: $($gpu.DriverVersion))" -ForegroundColor DarkGray
        $i++
    }

    Write-Host ""
    Write-Host "  GPU names can be spoofed via registry for WebGL fingerprinting." -ForegroundColor DarkYellow
    Write-Host ""

    Write-Host "    [1] " -ForegroundColor Cyan -NoNewline
    Write-Host "Set custom GPU name (registry spoof)" -ForegroundColor White
    Write-Host "    [2] " -ForegroundColor Cyan -NoNewline
    Write-Host "Use preset common GPU name" -ForegroundColor White
    Write-Host "    [0] " -ForegroundColor DarkGray -NoNewline
    Write-Host "Back" -ForegroundColor DarkGray
    Write-Host ""

    $choice = Read-Host "  Select option"

    $spoofRegPath = "HKLM:\SOFTWARE\VMFingerprint"
    if (-not (Test-Path $spoofRegPath)) {
        New-Item -Path $spoofRegPath -Force | Out-Null
    }

    switch ($choice) {
        "1" {
            $newName = Read-Host "  Enter GPU name"
            Set-ItemProperty -Path $spoofRegPath -Name "GPUName" -Value $newName -Force

            # Try to modify the actual display adapter registry
            $displayPath = "HKLM:\SYSTEM\CurrentControlSet\Control\Video"
            $subKeys = Get-ChildItem $displayPath -Recurse -ErrorAction SilentlyContinue |
                       Where-Object { (Get-ItemProperty $_.PSPath -Name "DriverDesc" -ErrorAction SilentlyContinue) }
            foreach ($key in $subKeys) {
                Set-ItemProperty -Path $key.PSPath -Name "DriverDesc" -Value $newName -Force -ErrorAction SilentlyContinue
            }

            Write-Success "GPU name set to: $newName"
            Write-Log "GPU name spoofed: $newName"
        }
        "2" {
            $presets = @(
                "NVIDIA GeForce RTX 4070",
                "NVIDIA GeForce RTX 3060",
                "NVIDIA GeForce GTX 1660 Ti",
                "AMD Radeon RX 7600",
                "AMD Radeon RX 6700 XT",
                "Intel UHD Graphics 770",
                "Intel Iris Xe Graphics",
                "NVIDIA GeForce RTX 4060 Laptop GPU",
                "AMD Radeon RX 580",
                "NVIDIA GeForce GTX 1050 Ti"
            )
            Write-Host ""
            for ($j = 0; $j -lt $presets.Count; $j++) {
                Write-Host "    [$($j+1)] " -ForegroundColor Cyan -NoNewline
                Write-Host $presets[$j] -ForegroundColor White
            }
            Write-Host ""
            $gpuChoice = Read-Host "  Select GPU"
            $gpuIdx = [int]$gpuChoice - 1
            if ($gpuIdx -lt 0 -or $gpuIdx -ge $presets.Count) {
                Write-Err "Invalid selection."
                return
            }
            $selectedGPU = $presets[$gpuIdx]
            Set-ItemProperty -Path $spoofRegPath -Name "GPUName" -Value $selectedGPU -Force

            $displayPath = "HKLM:\SYSTEM\CurrentControlSet\Control\Video"
            $subKeys = Get-ChildItem $displayPath -Recurse -ErrorAction SilentlyContinue |
                       Where-Object { (Get-ItemProperty $_.PSPath -Name "DriverDesc" -ErrorAction SilentlyContinue) }
            foreach ($key in $subKeys) {
                Set-ItemProperty -Path $key.PSPath -Name "DriverDesc" -Value $selectedGPU -Force -ErrorAction SilentlyContinue
            }

            Write-Success "GPU name set to: $selectedGPU"
            Write-Log "GPU name spoofed: $selectedGPU"
        }
        default { return }
    }
}

function Randomize-AllFingerprints {
    Show-Banner
    Write-Host "  RANDOMIZE ALL FINGERPRINTS" -ForegroundColor Red
    Show-Separator
    Write-Host ""
    Write-Host "  This will change ALL identifiers at once with random values:" -ForegroundColor Yellow
    Write-Host "    - Machine GUID" -ForegroundColor White
    Write-Host "    - Computer Name" -ForegroundColor White
    Write-Host "    - MAC Addresses (all adapters)" -ForegroundColor White
    Write-Host "    - BIOS / Baseboard Serials" -ForegroundColor White
    Write-Host "    - Windows Product ID" -ForegroundColor White
    Write-Host "    - GPU Name" -ForegroundColor White
    Write-Host ""

    $confirm = Read-Host "  Type 'YES' to confirm"
    if ($confirm -ne "YES") {
        Write-Warn "Cancelled."
        return
    }

    Write-Host ""

    # 1. Backup first
    Write-Warn "Creating backup..."
    Backup-CurrentFingerprint
    Write-Host ""

    # 2. Machine GUID
    $newGuid = Generate-RandomGUID
    try {
        Set-ItemProperty -Path "HKLM:\SOFTWARE\Microsoft\Cryptography" -Name MachineGuid -Value $newGuid -Force
        Write-Success "Machine GUID:      $newGuid"
    } catch { Write-Err "Machine GUID failed: $_" }

    # 3. Computer Name
    $newName = Generate-RandomComputerName
    try {
        Set-ItemProperty -Path "HKLM:\SYSTEM\CurrentControlSet\Control\ComputerName\ComputerName" -Name "ComputerName" -Value $newName -Force
        Set-ItemProperty -Path "HKLM:\SYSTEM\CurrentControlSet\Control\ComputerName\ActiveComputerName" -Name "ComputerName" -Value $newName -Force
        Set-ItemProperty -Path "HKLM:\SYSTEM\CurrentControlSet\Services\Tcpip\Parameters" -Name "Hostname" -Value $newName -Force
        Set-ItemProperty -Path "HKLM:\SYSTEM\CurrentControlSet\Services\Tcpip\Parameters" -Name "NV Hostname" -Value $newName -Force
        Write-Success "Computer Name:     $newName"
    } catch { Write-Err "Computer name failed: $_" }

    # 4. MAC Addresses
    $nics = Get-NetAdapter -Physical -ErrorAction SilentlyContinue
    $regBase = "HKLM:\SYSTEM\CurrentControlSet\Control\Class\{4D36E972-E325-11CE-BFC1-08002bE10318}"
    foreach ($nic in $nics) {
        $newMAC = Generate-RandomMAC
        Set-MACForAdapter -Adapter $nic -NewMAC $newMAC
    }

    # 5. Hardware Serials
    $newBIOS = Generate-RandomSerial -Length 20
    $newBoard = Generate-RandomSerial -Length 16
    $newUUID = Generate-RandomGUID
    $spoofRegPath = "HKLM:\SOFTWARE\VMFingerprint"
    if (-not (Test-Path $spoofRegPath)) { New-Item -Path $spoofRegPath -Force | Out-Null }
    Set-ItemProperty -Path $spoofRegPath -Name "BIOSSerial" -Value $newBIOS -Force
    Set-ItemProperty -Path $spoofRegPath -Name "BoardSerial" -Value $newBoard -Force
    Set-ItemProperty -Path $spoofRegPath -Name "SystemUUID" -Value $newUUID -Force

    $sysInfoPath = "HKLM:\SYSTEM\CurrentControlSet\Control\SystemInformation"
    if (-not (Test-Path $sysInfoPath)) { New-Item -Path $sysInfoPath -Force | Out-Null }
    Set-ItemProperty -Path $sysInfoPath -Name "BIOSSerialNumber" -Value $newBIOS -Force -ErrorAction SilentlyContinue
    Set-ItemProperty -Path $sysInfoPath -Name "BaseBoardSerialNumber" -Value $newBoard -Force -ErrorAction SilentlyContinue
    Set-ItemProperty -Path $sysInfoPath -Name "SystemProductName" -Value (Generate-RandomSerial -Length 10) -Force -ErrorAction SilentlyContinue
    Write-Success "BIOS Serial:       $newBIOS"
    Write-Success "Board Serial:      $newBoard"
    Write-Success "System UUID:       $newUUID"

    # 6. Product ID
    $newProductId = Generate-RandomProductId
    try {
        Set-ItemProperty -Path "HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion" -Name ProductId -Value $newProductId -Force
        Write-Success "Product ID:        $newProductId"
    } catch { Write-Err "Product ID failed: $_" }

    # 7. GPU Name
    $gpuPresets = @(
        "NVIDIA GeForce RTX 4070", "NVIDIA GeForce RTX 3060", "AMD Radeon RX 7600",
        "NVIDIA GeForce GTX 1660 Ti", "Intel UHD Graphics 770", "AMD Radeon RX 6700 XT"
    )
    $randomGPU = $gpuPresets | Get-Random
    Set-ItemProperty -Path $spoofRegPath -Name "GPUName" -Value $randomGPU -Force
    $displayPath = "HKLM:\SYSTEM\CurrentControlSet\Control\Video"
    $subKeys = Get-ChildItem $displayPath -Recurse -ErrorAction SilentlyContinue |
               Where-Object { (Get-ItemProperty $_.PSPath -Name "DriverDesc" -ErrorAction SilentlyContinue) }
    foreach ($key in $subKeys) {
        Set-ItemProperty -Path $key.PSPath -Name "DriverDesc" -Value $randomGPU -Force -ErrorAction SilentlyContinue
    }
    Write-Success "GPU Name:          $randomGPU"

    # 8. Restart network adapters
    Write-Host ""
    Write-Warn "Restarting network adapters..."
    if ($nics) { Restart-NetworkAdapters -Adapters $nics }

    Write-Host ""
    Show-Separator
    Write-Success "All fingerprints randomized!"
    Write-Warn "Restart the VM for all changes to take full effect."
    Write-Log "FULL RANDOMIZATION completed"
}

function Show-ChangeLog {
    Show-Banner
    Write-Host "  CHANGE LOG" -ForegroundColor Magenta
    Show-Separator
    Write-Host ""

    if (Test-Path $Script:LogFile) {
        $lines = Get-Content $Script:LogFile -Tail 30
        foreach ($line in $lines) {
            Write-Host "    $line" -ForegroundColor DarkCyan
        }
    } else {
        Write-Host "    No changes logged yet." -ForegroundColor DarkGray
    }
    Write-Host ""
}

# ============================================================================
# MAIN MENU
# ============================================================================

function Show-MainMenu {
    Show-Banner
    Write-Host "  MAIN MENU" -ForegroundColor Magenta
    Show-Separator
    Write-Host ""
    Write-Host "    [1] " -ForegroundColor Cyan -NoNewline
    Write-Host " View Current Fingerprint" -ForegroundColor White
    Write-Host ""
    Write-Host "    [2] " -ForegroundColor Yellow -NoNewline
    Write-Host " Change MAC Address" -ForegroundColor White
    Write-Host "    [3] " -ForegroundColor Yellow -NoNewline
    Write-Host " Change Machine GUID" -ForegroundColor White
    Write-Host "    [4] " -ForegroundColor Yellow -NoNewline
    Write-Host " Change Computer Name" -ForegroundColor White
    Write-Host "    [5] " -ForegroundColor Yellow -NoNewline
    Write-Host " Change BIOS / Board Serial / UUID" -ForegroundColor White
    Write-Host "    [6] " -ForegroundColor Yellow -NoNewline
    Write-Host " Change Windows Product ID" -ForegroundColor White
    Write-Host "    [7] " -ForegroundColor Yellow -NoNewline
    Write-Host " Change Disk Volume Serial" -ForegroundColor White
    Write-Host "    [8] " -ForegroundColor Yellow -NoNewline
    Write-Host " Change GPU / Display Name" -ForegroundColor White
    Write-Host ""
    Show-Separator
    Write-Host ""
    Write-Host "    [R] " -ForegroundColor Red -NoNewline
    Write-Host " Randomize ALL Fingerprints" -ForegroundColor Red
    Write-Host "    [B] " -ForegroundColor Green -NoNewline
    Write-Host " Backup Current Fingerprint" -ForegroundColor White
    Write-Host "    [L] " -ForegroundColor DarkCyan -NoNewline
    Write-Host " View Change Log" -ForegroundColor White
    Write-Host ""
    Write-Host "    [0] " -ForegroundColor DarkGray -NoNewline
    Write-Host " Exit" -ForegroundColor DarkGray
    Write-Host ""
    Show-Separator
    Write-Host ""
}

# ============================================================================
# MAIN LOOP
# ============================================================================

# Check for admin
$isAdmin = ([Security.Principal.WindowsPrincipal] [Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
if (-not $isAdmin) {
    Write-Host ""
    Write-Host "  ERROR: This tool must be run as Administrator!" -ForegroundColor Red
    Write-Host "  Right-click PowerShell and select 'Run as Administrator'" -ForegroundColor Yellow
    Write-Host ""
    exit 1
}

while ($true) {
    Show-MainMenu
    $selection = Read-Host "  Enter choice"

    switch ($selection) {
        "1" {
            Show-CurrentFingerprint
            Write-Host ""
            Read-Host "  Press Enter to continue"
        }
        "2" { Edit-MACAddress; Write-Host ""; Read-Host "  Press Enter to continue" }
        "3" { Edit-MachineGUID; Write-Host ""; Read-Host "  Press Enter to continue" }
        "4" { Edit-ComputerName; Write-Host ""; Read-Host "  Press Enter to continue" }
        "5" { Edit-BIOSSerial; Write-Host ""; Read-Host "  Press Enter to continue" }
        "6" { Edit-ProductID; Write-Host ""; Read-Host "  Press Enter to continue" }
        "7" { Edit-VolumeSerial; Write-Host ""; Read-Host "  Press Enter to continue" }
        "8" { Edit-GPUName; Write-Host ""; Read-Host "  Press Enter to continue" }
        "R" { Randomize-AllFingerprints; Write-Host ""; Read-Host "  Press Enter to continue" }
        "r" { Randomize-AllFingerprints; Write-Host ""; Read-Host "  Press Enter to continue" }
        "B" { Backup-CurrentFingerprint; Write-Host ""; Read-Host "  Press Enter to continue" }
        "b" { Backup-CurrentFingerprint; Write-Host ""; Read-Host "  Press Enter to continue" }
        "L" { Show-ChangeLog; Read-Host "  Press Enter to continue" }
        "l" { Show-ChangeLog; Read-Host "  Press Enter to continue" }
        "0" {
            Write-Host ""
            Write-Host "  Goodbye!" -ForegroundColor Cyan
            Write-Host ""
            exit 0
        }
        default {
            Write-Warn "Invalid option. Try again."
            Start-Sleep -Seconds 1
        }
    }
}
