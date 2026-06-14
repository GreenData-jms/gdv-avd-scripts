#Requires -RunAsAdministrator
<#
.SYNOPSIS
    Force-register Claude Desktop 1.12603.1.0 in existing user profiles on vmpool0.

.DESCRIPTION
    Runs as SYSTEM via az vm run-command. For each target user it:
      1. Writes a per-user helper .ps1 to C:\Windows\Temp\ClaudeReg\
      2. Registers a Windows Scheduled Task with LogonType Interactive
         so the registration runs inside the user's own desktop session.
      3. Sets an AtLogon trigger (catches users not currently active).
      4. Calls Start-ScheduledTask immediately (fires for any active session).

    jms@ special handling: helper script first removes the stale per-user
    Claude 1.11847.5.0 install, waits 10 s, then registers 1.12603.1.0.

.NOTES
    BP-003 Track A — post-install user registration fix
    VM: vmpool0 | RG: rg-adv-pooled | Sub: d39ad50c-78fd-439c-beeb-c958403f8ade
    Package family: Claude_pzs8sxrjxfjjc | Target version: 1.12603.1.0
#>

param()

$ErrorActionPreference = 'Stop'
function ts { "[$(Get-Date -f 'HH:mm:ss')]" }

Write-Host "$(ts) ===== Claude Desktop Force-Registration ====="

# --- 1. Locate provisioned package manifest ----------------------------------
$ProvPkg = Get-AppxProvisionedPackage -Online |
    Where-Object { $_.PackageName -match 'Claude' } |
    Select-Object -First 1

if (-not $ProvPkg) {
    throw "No Claude provisioned package found. Confirm Add-AppxProvisionedPackage ran successfully."
}

$ManifestPath = "C:\Program Files\WindowsApps\$($ProvPkg.PackageName)\AppxManifest.xml"
Write-Host "$(ts) Package : $($ProvPkg.PackageName)"
Write-Host "$(ts) Manifest: $ManifestPath"

if (-not (Test-Path $ManifestPath)) {
    throw "AppxManifest.xml not found at $ManifestPath — package may not be fully staged."
}

# --- 2. Write per-user helper scripts to temp location -----------------------
$TempDir = 'C:\Windows\Temp\ClaudeReg'
New-Item -ItemType Directory -Path $TempDir -Force | Out-Null

# Standard helper: just register (Demo Test, jeff, nicole)
$StandardHelper = @"
# Register Claude Desktop - standard user
`$manifest = '$ManifestPath'
Write-Host "[`$(Get-Date -f 'HH:mm:ss')] Registering Claude from `$manifest"
Add-AppxPackage -Register -DisableDevelopmentMode `$manifest
Write-Host "[`$(Get-Date -f 'HH:mm:ss')] Done."
"@
Set-Content -Path "$TempDir\Register-Standard.ps1" -Value $StandardHelper -Encoding UTF8

# jms@ helper: remove old per-user install, then register
$JmsHelper = @"
# Register Claude Desktop - jms@ (removes stale 1.11847.5.0 first)
`$manifest = '$ManifestPath'
Write-Host "[`$(Get-Date -f 'HH:mm:ss')] Checking for old Claude installs..."
`$oldPkgs = Get-AppxPackage | Where-Object { `$_.Name -match 'Claude' -and `$_.Version -notlike '1.12603*' }
if (`$oldPkgs) {
    foreach (`$pkg in `$oldPkgs) {
        Write-Host "[`$(Get-Date -f 'HH:mm:ss')] Removing: `$(`$pkg.PackageFullName)"
        Remove-AppxPackage -Package `$pkg.PackageFullName -ErrorAction SilentlyContinue
    }
    Write-Host "[`$(Get-Date -f 'HH:mm:ss')] Waiting 10 s for removal to settle..."
    Start-Sleep -Seconds 10
} else {
    Write-Host "[`$(Get-Date -f 'HH:mm:ss')] No old Claude version found - proceeding directly."
}
Write-Host "[`$(Get-Date -f 'HH:mm:ss')] Registering Claude 1.12603.1.0 from `$manifest"
Add-AppxPackage -Register -DisableDevelopmentMode `$manifest
Write-Host "[`$(Get-Date -f 'HH:mm:ss')] Done."
"@
Set-Content -Path "$TempDir\Register-JMS.ps1" -Value $JmsHelper -Encoding UTF8

Write-Host "$(ts) Helper scripts written to $TempDir"

# --- 3. Helper function: register + trigger a per-user task ------------------
$TaskSettings = New-ScheduledTaskSettingsSet `
    -ExecutionTimeLimit     (New-TimeSpan -Minutes 10) `
    -DeleteExpiredTaskAfter (New-TimeSpan -Days 3)     `
    -MultipleInstances      IgnoreNew

function Register-ClaudeTask {
    param(
        [string]$UserPrincipal,  # e.g. "AzureAD\DemoTest"
        [string]$ScriptFile      # full path to helper .ps1 on the VM
    )

    $TaskName = "ClaudeReg_$($UserPrincipal -replace '[\\@. ]', '_')"
    Write-Host ""
    Write-Host "$(ts) -- $UserPrincipal ---"

    $Action = New-ScheduledTaskAction `
        -Execute  'powershell.exe' `
        -Argument "-NoProfile -NonInteractive -WindowStyle Hidden -File `"$ScriptFile`""

    $Principal = New-ScheduledTaskPrincipal `
        -UserId    $UserPrincipal `
        -LogonType Interactive `
        -RunLevel  Highest

    # AtLogon trigger ensures task fires even if user isn't active right now
    $Trigger = New-ScheduledTaskTrigger -AtLogOn -User $UserPrincipal

    Register-ScheduledTask `
        -TaskName  $TaskName `
        -Action    $Action `
        -Principal $Principal `
        -Trigger   $Trigger `
        -Settings  $TaskSettings `
        -Force | Out-Null

    Write-Host "$(ts)   Registered: $TaskName"

    # Immediate trigger - succeeds if user has an active interactive session
    try {
        Start-ScheduledTask -TaskName $TaskName -ErrorAction Stop
        Write-Host "$(ts)   Triggered immediately (user session detected)"
    } catch {
        Write-Host "$(ts)   Deferred - will fire at $UserPrincipal's next logon"
    }
}

# --- 4. Register tasks for each user -----------------------------------------
Register-ClaudeTask -UserPrincipal 'AzureAD\DemoTest' -ScriptFile "$TempDir\Register-Standard.ps1"
Register-ClaudeTask -UserPrincipal 'AzureAD\jeff'     -ScriptFile "$TempDir\Register-Standard.ps1"
Register-ClaudeTask -UserPrincipal 'AzureAD\nicole'   -ScriptFile "$TempDir\Register-Standard.ps1"
Register-ClaudeTask -UserPrincipal 'AzureAD\jms'      -ScriptFile "$TempDir\Register-JMS.ps1"

# --- 5. Summary --------------------------------------------------------------
Write-Host ""
Write-Host "$(ts) ===== Registration Complete ====="
Write-Host "$(ts) Registered tasks:"
Get-ScheduledTask |
    Where-Object { $_.TaskName -match 'ClaudeReg_' } |
    Select-Object TaskName, State |
    Format-Table -AutoSize

Write-Host "$(ts) Active sessions (for reference):"
try {
    query session 2>$null | Select-String -Pattern 'Active|Disc'
} catch { Write-Host "$(ts)   (query session unavailable in SYSTEM context)" }

Write-Host ""
Write-Host "$(ts) Next step: confirm Claude icon appears for each user after logon."
Write-Host "$(ts) Tasks auto-delete after 3 days once expired."
