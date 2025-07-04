# Patch Master for Azure

# Back story

Patching is not the most exciting thing to be doing on a Sunday. Having worked with a number of Patching tools over the years, they have all had thier quirks most come with a a price tag that can be quite intimadating. 

I have worked with a number of these tools SCCM, BatchPatch, AWX (Ansible Tower), these all have thier stringth and weaknesses. When a coworker mentions he was using the Update features to do patching that triggered the how can I script this brain cell, As most of Azure features have a PowerShell module, az cli commend, and, or API that can be used to interact with them. And so down the rabbit burrow I went. 

While I have coded in other languages in the past (many, many years ago),I do all of my work in PowerShell these days, it's on all windows machines, no setting up needed, use notepad or ISE ship with windows and your on your way. So thats why I have gone with powershell at this point. 

Next the configuration needs to be simple no messing around with brackets, braces and white spaces, so I decided on the .csv file format. Its a straight forward format that can be edited with the same editors as PowerShell or a spreadsheet editor... no names mentioned lol.. When you have a lot of servers to Patch this can simplify things.. And .csv files are well supported in PowerShell. 

The the script itself, need to be self contained. No modules that would need to be updated and as few dependcies as possible. At this time the only dependcies are the official az PowerShell Modules. Download the script configure your .csv and your ready to go. 

Now that your asleep at your computer here are some of the more intersting details.

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
- All server must be Azure Virtual Machines or Azure Connected Machines (Azure Arc)
- Windows PowerShell 5.1
- Az PowerShell module installed
- Authenticated to Azure (see below)

## Current Limitations

- The script runs under the logged-in Azure account's context and is limited to the current subscription. Use `Set-AzContext` to change the subscription.
- Filtering specific patches is not supported yet.
- There may be Azure-imposed limits (to be investigated).

## Known Issues
- The Az powershell commands succeed with the error 
    "Microsoft.Azure.Management.Compute.Models.ApiError"
    checking the server manual confrims the succcess full installation. 
---

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



For more details, see the script comments and Docs/Invoke-AzurePatchMaster.md.


