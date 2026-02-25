# -*- coding: utf-8 -*-

# Title: 自动生成多个具有独立环境的 Chrome 浏览器

# Usage: .\chrome.ps1
#   The script will prompt you to enter a base directory.
#   It will create Chrome_UserData and Chrome_ShortCuts folders inside it,
#   then generate Chrome shortcuts with independent user profiles.

# ==================== Configuration ====================

# Chrome executable path
$TargetPath = "C:\Program Files\Google\Chrome\Application\chrome.exe"

# Chrome working directory
$WorkingDirectory = "C:\Program Files\Google\Chrome\Application"

# ==================== Input ====================

Write-Host ""
Write-Host "========================================" -ForegroundColor Cyan
Write-Host "  Chrome Multi-Profile Shortcut Generator" -ForegroundColor Cyan
Write-Host "========================================" -ForegroundColor Cyan
Write-Host ""

$BaseDir = Read-Host "Enter the base directory (e.g. D:\fenliulanqi)"

# Validate directory input
if ([string]::IsNullOrWhiteSpace($BaseDir)) {
    Write-Host "[ERROR] No directory provided. Exiting." -ForegroundColor Red
    exit 1
}

$ProfileInput = Read-Host "Enter the number of profiles to create (default: 10)"

# Validate profile count input
if ([string]::IsNullOrWhiteSpace($ProfileInput)) {
    $ProfileCount = 10
    Write-Host "[INFO] Using default profile count: 10" -ForegroundColor Yellow
} elseif ($ProfileInput -match '^\d+$' -and [int]$ProfileInput -gt 0) {
    $ProfileCount = [int]$ProfileInput
} else {
    Write-Host "[ERROR] Invalid number. Please enter a positive integer. Exiting." -ForegroundColor Red
    exit 1
}

# ==================== Setup Directories ====================

$UserDataPath = Join-Path $BaseDir "Chrome_UserData"
$ShortcutPath = Join-Path $BaseDir "Chrome_ShortCuts"

Write-Host ""
Write-Host "[INFO] Base directory  : $BaseDir" -ForegroundColor Yellow
Write-Host "[INFO] User data path  : $UserDataPath" -ForegroundColor Yellow
Write-Host "[INFO] Shortcut path   : $ShortcutPath" -ForegroundColor Yellow
Write-Host "[INFO] Chrome exe      : $TargetPath" -ForegroundColor Yellow
Write-Host "[INFO] Profile count   : $ProfileCount" -ForegroundColor Yellow
Write-Host ""

# Create directories if they don't exist
if (!(Test-Path $UserDataPath)) {
    New-Item -ItemType Directory -Path $UserDataPath -Force | Out-Null
    Write-Host "[OK] Created user data directory: $UserDataPath" -ForegroundColor Green
} else {
    Write-Host "[OK] User data directory already exists: $UserDataPath" -ForegroundColor Green
}

if (!(Test-Path $ShortcutPath)) {
    New-Item -ItemType Directory -Path $ShortcutPath -Force | Out-Null
    Write-Host "[OK] Created shortcut directory: $ShortcutPath" -ForegroundColor Green
} else {
    Write-Host "[OK] Shortcut directory already exists: $ShortcutPath" -ForegroundColor Green
}

Write-Host ""

# ==================== Generate Shortcuts ====================

Write-Host "[INFO] Generating $ProfileCount Chrome shortcuts..." -ForegroundColor Yellow
Write-Host ""

$array = 1..$ProfileCount

foreach ($n in $array) {

    $x = $n.ToString()

    $ShortcutFile = Join-Path $ShortcutPath ("Chrome_" + $x + ".lnk")

    $WScriptShell = New-Object -ComObject WScript.Shell

    $Shortcut = $WScriptShell.CreateShortcut($ShortcutFile)

    $Shortcut.TargetPath = $TargetPath

    $Shortcut.Arguments = "--user-data-dir=`"$UserDataPath\$x`""

    $Shortcut.WorkingDirectory = $WorkingDirectory

    $Shortcut.Description = "Chrome Profile $x"

    $IconPath = Join-Path $PSScriptRoot "icons\icon_$x.ico"
    if (Test-Path $IconPath) {
        $Shortcut.IconLocation = $IconPath
    }

    $Shortcut.Save()

    Write-Host "  [OK] Created shortcut: Chrome_$x.lnk  (profile: $x)" -ForegroundColor Green
}

# ==================== Done ====================

Write-Host ""
Write-Host "========================================" -ForegroundColor Cyan
Write-Host "  All $ProfileCount shortcuts created successfully!" -ForegroundColor Cyan
Write-Host "========================================" -ForegroundColor Cyan
Write-Host ""
Write-Host "[INFO] Opening shortcut directory..." -ForegroundColor Yellow

# Open the shortcuts directory in Explorer
Invoke-Item $ShortcutPath