# gdv-avd-scripts

Private script repository for GreenData Ventures Azure Virtual Desktop deployment and management automation.

## Structure

- `Scripts/` — PowerShell scripts for session host configuration, FSLogix, app masking, and Intune deployment
- `avd-transfer-test.ps1` — Pattern 3 transfer test script

## Pattern 3

Scripts are delivered to session hosts via Pattern 3: Cowork pushes scripts here via GitHub MCP, Cloud Shell retrieves the PAT from Azure Key Vault (`kv-gdv-avd-prod`), and scripts are fetched with `curl -H "Authorization: token $PAT"` and executed via `Invoke-AzVMRunCommand`.

## Reference

See `~/Documents/Claude/Projects/Azure VDI Expert/CLAUDE.md` for full environment documentation.
