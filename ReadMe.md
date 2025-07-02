# Patch Master for Azure

Patch Master for Azure is a PowerShell-based solution to automate patching for both Windows and Linux servers, supporting Azure Virtual Machines and Azure Arc-connected (on-premises or other cloud) servers. It is designed to be simple, flexible, and easy to use for both single-server and bulk patching scenarios.

## Why?

Existing tools (SCCM, AWX/Ansible Tower, Batch Patch, etc.) are powerful but often complex or limited in hybrid Azure/on-prem environments. Azure's built-in update features are useful, but advanced patching (especially at scale) can be cumbersome and require extra steps or costs. This script leverages the Az PowerShell modules to provide a unified, scriptable patching workflow for all your servers.

## Features

- Supports Windows and Linux
- Supports Azure Virtual Machines and Azure Arc-connected servers
- Uses native patching sources (Windows WSUS, Linux repositories)
- Check patch status of a server
- Patch a single server
- Patch multiple servers in sequence or in parallel (CSV-driven)
- Logging of all actions and results
- Logs assessment and installation results separately
- Selective patching based on patch classification:
  - **Windows:** Critical, Security, UpdateRollup, ServicePack, Definition, Updates, FeaturePack, Tools
  - **Linux:** Critical, Security, Other
- Manage reboots: IfRequired, Always, Never
- Maximum duration: Limit the maximum time allowed for installation

## Usage

### Prerequisites
- PowerShell 7.x or Windows PowerShell 5.1+
- Az PowerShell module installed
- Authenticated to Azure (see below)

### Authentication
Before running the script, authenticate to Azure:

```powershell
Connect-AzAccount
```

### Single Server Example

```powershell
# Assess and install patches (default)
.\Invoke-PatchAzureMachines.ps1 -ResourceGroupName "MyResourceGroup" -ServerName "MyVM"

# Assess only
.\Invoke-PatchAzureMachines.ps1 -ResourceGroupName "MyResourceGroup" -ServerName "MyVM" -AssessOnly

# Install only
.\Invoke-PatchAzureMachines.ps1 -ResourceGroupName "MyResourceGroup" -ServerName "MyVM" -InstallOnly
```

### Batch/Parallel Example (CSV)

Prepare a CSV file (e.g., `PatchingList.csv`) with columns:

```
Order,ServerName,ResourceGroupName,Action,MaximumDuration,RebootSetting,WindowsClassificationsToInclude,LinuxClassificationsToInclude
```

Run serially:

```powershell
.\Invoke-PatchAzureMachines.ps1 -CSVPath .\PatchingList.csv
```

Run in parallel (jobs):

```powershell
.\Invoke-PatchAzureMachines.ps1 -CSVPath .\PatchingList.csv -Jobs -MaxJobs 3
```

## Logging & Reporting

- Logs: `C:\ProgramData\GDMTT\Logs\Invoke-PatchAzureMachines-<date>.log` (per-job log files in parallel mode)
- Assessment results: `C:\ProgramData\GDMTT\Reporting\Invoke-PatchAzureMachines-Assessment.csv`
- Install results: `C:\ProgramData\GDMTT\Reporting\Invoke-PatchAzureMachines-Install.csv`
- All logs include timestamps, server name, log level (Info, Warn, Error), and detailed messages

## Current Limitations

- The script runs under the logged-in Azure account's context and is limited to the current subscription. Use `Set-AzContext` to change the subscription.
- Filtering specific patches is not supported yet.
- There may be Azure-imposed limits (to be investigated).

---

For more details, see the script comments and Docs/Invoke-PatchAzureMachines.md.

