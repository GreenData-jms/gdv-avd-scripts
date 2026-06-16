# Invoke-EnrollAndCapture.ps1
# Triggers MDM auto-enrollment on a GDV AVD session host and writes
# the dsregcmd /status output + enroller result to Key Vault for retrieval.
#
# Run from Cloud Shell (pwsh):
#   PAT=$(az keyvault secret show --vault-name kv-gdv-avd-prod --name GDV-GitHub-PAT --query value -o tsv)
#   curl -s -H "Authorization: token $PAT" \
#     "https://raw.githubusercontent.com/GreenData-jms/gdv-avd-scripts/main/Scripts/Invoke-EnrollAndCapture.ps1" \
#     -o /tmp/Invoke-EnrollAndCapture.ps1
#   pwsh /tmp/Invoke-EnrollAndCapture.ps1

param(
    [string]$RG        = "rg-adv-pooled",
    [string]$VM        = "vmpool0",
    [string]$VaultName = "kv-gdv-avd-prod",
    [string]$SecretName = "avd-enroll-output"
)

$RemoteScript = @'
$lines = @()

# Trigger MDM enrollment
try {
    $enrollOut = & "$env:windir\system32\deviceenroller.exe" /o MDMEnrollment /c 2>&1
    $lines += "=ENROLL_RESULT="
    $lines += ($enrollOut | ForEach-Object { "$_" })
} catch {
    $lines += "=ENROLL_ERROR= $($_.Exception.Message)"
}

# Fallback if deviceenroller returns nothing meaningful
$lines += ""
$lines += "=MDM_STATUS (dsregcmd)="
try {
    $lines += (dsregcmd /status | Select-String -Pattern "MDM|Mdm" | Out-String).Trim()
} catch {
    $lines += "dsregcmd error: $($_.Exception.Message)"
}

# Full Entra join status for context
$lines += ""
$lines += "=ENTRA_JOIN_STATUS="
try {
    $lines += (dsregcmd /status | Select-String -Pattern "AzureAd|WorkplaceJoined|TenantId" | Out-String).Trim()
} catch {
    $lines += "dsregcmd entra section error: $($_.Exception.Message)"
}

$lines -join "`n"
'@

Write-Host "[1/3] Running Invoke-AzVMRunCommand on $VM in $RG ..."
try {
    $result = Invoke-AzVMRunCommand `
        -ResourceGroupName $RG `
        -VMName $VM `
        -CommandId 'RunPowerShellScript' `
        -ScriptString $RemoteScript `
        -ErrorAction Stop
} catch {
    Write-Host "ERROR: Invoke-AzVMRunCommand failed: $($_.Exception.Message)"
    exit 1
}

$stdout = ($result.Value | Where-Object { $_.Code -like "*StdOut*" }).Message
$stderr = ($result.Value | Where-Object { $_.Code -like "*StdErr*" }).Message

$combined = "=== STDOUT ===`n$stdout`n=== STDERR ===`n$stderr"

Write-Host "[2/3] Writing output to /tmp/enroll-output.txt ..."
$combined | Out-File /tmp/enroll-output.txt -Encoding UTF8

Write-Host "[3/3] Uploading to Key Vault secret '$SecretName' ..."
az keyvault secret set `
    --vault-name $VaultName `
    --name $SecretName `
    --file /tmp/enroll-output.txt `
    --output none

if ($LASTEXITCODE -eq 0) {
    Write-Host "SUCCESS: Results available in KV secret '$SecretName'"
    Write-Host ""
    Write-Host "--- STDOUT preview ---"
    Write-Host $stdout
} else {
    Write-Host "WARN: KV write may have failed. Raw stdout:"
    Write-Host $stdout
}
