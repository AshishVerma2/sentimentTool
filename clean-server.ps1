# clean-server.ps1
# Removes all voice-sentiment services, files and firewall rules from the server.
# Run on the server: powershell -ExecutionPolicy Bypass -File clean-server.ps1

$ErrorActionPreference = "SilentlyContinue"

$NssmExe    = "C:\tools\nssm\win64\nssm.exe"
$InstallRoot = "C:\voice-sentiment"

function Write-Step([string]$msg) {
    Write-Host "`n[$([datetime]::Now.ToString('HH:mm:ss'))] $msg" -ForegroundColor Cyan
}

# ---------------------------------------------------------------------------
# Step 1 - Stop and remove services
# ---------------------------------------------------------------------------
Write-Step "Stopping and removing services"

foreach ($svc in @("VoiceSentiment", "VoiceSentiment-SA")) {
    $existing = Get-Service -Name $svc -ErrorAction SilentlyContinue
    if ($existing) {
        Write-Host "  Stopping $svc ..." -ForegroundColor Gray
        & $NssmExe stop $svc confirm 2>&1 | Out-Null
        Start-Sleep -Seconds 2
        & $NssmExe remove $svc confirm 2>&1 | Out-Null
        Write-Host "  Removed: $svc" -ForegroundColor Yellow
    } else {
        Write-Host "  Not found: $svc"
    }
}

# ---------------------------------------------------------------------------
# Step 2 - Remove firewall rules
# ---------------------------------------------------------------------------
Write-Step "Removing firewall rules"

foreach ($name in @("VoiceSentiment-2700", "VoiceSentiment-SA-2701")) {
    $rule = Get-NetFirewallRule -DisplayName $name -ErrorAction SilentlyContinue
    if ($rule) {
        Remove-NetFirewallRule -DisplayName $name
        Write-Host "  Removed rule: $name" -ForegroundColor Yellow
    } else {
        Write-Host "  Not found: $name"
    }
}

# ---------------------------------------------------------------------------
# Step 3 - Delete application files
# ---------------------------------------------------------------------------
Write-Step "Deleting application files"

if (Test-Path $InstallRoot) {
    Remove-Item $InstallRoot -Recurse -Force
    Write-Host "  Deleted: $InstallRoot" -ForegroundColor Yellow
} else {
    Write-Host "  Not found: $InstallRoot"
}

# ---------------------------------------------------------------------------
# Done
# ---------------------------------------------------------------------------
Write-Host ""
Write-Host "=== Server cleaned ===" -ForegroundColor Green
Write-Host "Python and NSSM left in place (C:\Python312, C:\tools\nssm)."
Write-Host "Run server-setup.ps1 to reinstall."
