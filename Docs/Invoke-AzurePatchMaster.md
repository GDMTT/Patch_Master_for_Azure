# Invoke-AzurePatchMaster.ps1

## Overview

`Invoke-AzurePatchMaster.ps1` is a robust PowerShell script designed to automate patch assessment and installation for both Azure Virtual Machines (VMs) and Azure Arc Connected Machines. It supports both Windows and Linux operating systems, and can be used to patch a single server or process multiple servers in parallel using a CSV file. The script features detailed logging, error handling, and generates comprehensive reports for both assessment and installation operations.

## Features
- Supports both Azure VMs and Azure Arc Connected Machines
- Handles both Windows and Linux OS types
- Can patch a single server or multiple servers in batch (CSV) mode
- Parallel processing of patch jobs with per-job log files
- Robust logging to file and console
- Detailed reporting to CSV files (assessment and install results)
- Customizable patch classifications and reboot settings

## Authentication
Before running the script, you must be authenticated to Azure with an account that has sufficient permissions to manage VMs and/or Arc Connected Machines.

**To authenticate:**
1. Open a PowerShell session.
2. Run:
   ```powershell
   Connect-AzAccount
   ```
3. Follow the prompts to sign in.

> The script will check if you are authenticated and prompt for login if needed.

## Usage

### Single Server Mode
To assess and/or install patches on a single server:

```powershell
# Assess and install patches (default)
    .\Invoke-AzurePatchMaster.ps1 -ResourceGroupName "MyResourceGroup" -ServerName "MyVM"

# Assess only
    .\Invoke-AzurePatchMaster.ps1 -ResourceGroupName "MyResourceGroup" -ServerName "MyVM" -AssessOnly

# Install only
    .\Invoke-AzurePatchMaster.ps1 -ResourceGroupName "MyResourceGroup" -ServerName "MyVM" -InstallOnly
```

You can also specify:
- `-MaximumDuration` (e.g., 'PT1H')
- `-RebootSetting` (IfRequired, Always, Never)
- `-WindowsClassificationsToInclude` (for Windows VMs)
- `-LinuxClassificationsToInclude` (for Linux VMs)

### Batch/Parallel Mode (CSV)
To process multiple servers, create a CSV file (e.g., `PatchingList.csv`) with columns:

```
Order,ServerName,ResourceGroupName,Action,MaximumDuration,RebootSetting,WindowsClassificationsToInclude,LinuxClassificationsToInclude
```

Example usage:

```powershell
# Serial processing
    .\Invoke-AzurePatchMaster.ps1 -CSVPath .\PatchingList.csv

# Parallel processing (jobs)
    .\Invoke-AzurePatchMaster.ps1 -CSVPath .\PatchingList.csv -Jobs -MaxJobs 3
```

Each job in parallel mode gets a unique log file.

## Logging
- Logs are written to `C:\ProgramData\GDMTT\Logs\Invoke-PatchAzureMachines-<date>.log` by default.
- In parallel mode, each job gets a log file named `Invoke-PatchAzureMachines-Job<Number>_<ServerName>-<date>.log`.
- Logs include timestamps, server name, log level (Info, Warn, Error), and detailed messages for all operations.

## Reporting
- Assessment results are written to: `C:\ProgramData\GDMTT\Reporting\Invoke-PatchAzureMachines-Assessment.csv`
- Install results are written to: `C:\ProgramData\GDMTT\Reporting\Invoke-PatchAzureMachines-Install.csv`
- Each CSV includes all output properties as columns. The install CSV lists installed patch names in the `Patches` column (semicolon-separated).

## Additional Notes
- The script automatically detects the OS type and applies the correct patch classification parameters.
- Errors and warnings are logged and reported in the output files.
- For more details, see the script comments and parameter documentation at the top of `Invoke-PatchAzureMachines.ps1`.
