<#
.SYNOPSIS
    Assess and install patches on Azure VMs or Azure Arc Connected Machines.

.DESCRIPTION
    This script checks if a specified server is an Azure VM or Azure Arc Connected Machine, then performs patch assessment and/or installation using the appropriate Azure PowerShell commands. It supports both Windows and Linux OS types, allows classification filtering, and logs all actions and outputs.

.PARAMETER ResourceGroupName
    The name of the Azure Resource Group containing the server.

.PARAMETER ServerName
    The name of the Azure VM or Azure Arc Connected Machine to patch.

.PARAMETER AssessOnly
    If specified, only performs patch assessment (no installation).

.PARAMETER InstallOnly
    If specified, only installs patches (no assessment).

.PARAMETER MaximumDuration
    The maximum duration allowed for the patch operation (default: 'PT1H').

.PARAMETER RebootSetting
    The reboot setting for the patch operation (default: 'IfRequired').

.PARAMETER WindowsClassificationsToInclude
    Patch classifications to include for Windows (default: Critical, Security, UpdateRollup, ServicePack, Definition, Updates).
    Valid options: Critical, Security, UpdateRollup, ServicePack, Definition, Updates, FeaturePack, Tools

.PARAMETER LinuxClassificationsToInclude
    Patch classifications to include for Linux (default: Critical, Security).
    Valid options: Critical, Security, other

.PARAMETER LogFilePath
    The path to the log file. Defaults to C:\programfiles\GDMTT\Logs\Invoke-PatchAzureMachines-<date>.log

.EXAMPLE
    .\Invoke-PatchAzureMachines.ps1 -ResourceGroupName 'MyRG' -ServerName 'MyVM'

.NOTES
    Author: Your Name
    Date: 2025-06-19

#>
[CmdletBinding(DefaultParameterSetName='SingleServer')]
param (
    [Parameter(Mandatory=$true, ParameterSetName='SingleServer')]
    [string]$ResourceGroupName,
    [Parameter(Mandatory=$true, ParameterSetName='SingleServer')]
    [string]$ServerName,
    [Parameter(ParameterSetName='SingleServer')]
    [switch]$AssessOnly, # Only perform assessment
    [Parameter(ParameterSetName='SingleServer')]
    [switch]$InstallOnly, # Only perform installation
    [Parameter(ParameterSetName='SingleServer')]
    [string]$MaximumDuration = 'PT1H', # Max duration for patching
    [Parameter(ParameterSetName='SingleServer')]
    [string]$RebootSetting = 'IfRequired', # Reboot setting for patching
    [Parameter(ParameterSetName='SingleServer')]
    [ValidateSet("Critical","Security","UpdateRollup","ServicePack","Definition","Updates","FeaturePack","Tools")][string[]]$WindowsClassificationsToInclude = @("Critical","Security","UpdateRollup","ServicePack","Definition","Updates"),
    [Parameter(ParameterSetName='SingleServer')]
    [ValidateSet("Critical","Security","other")][string[]]$LinuxClassificationsToInclude = @("Critical","Security"),
    [Parameter(ParameterSetName='SingleServer')]
    [string]$LogFilePath = $(Join-Path -Path 'C:\programfiles\GDMTT\Logs' -ChildPath ("Invoke-PatchAzureMachines-$(Get-Date -Format 'yyyyMMdd').log")),

    [Parameter(Mandatory=$true, ParameterSetName='CSV')]
    [string]$CSVPath,

    [Parameter(ParameterSetName='CSV')]
    [switch]$Jobs,
    [Parameter(ParameterSetName='CSV')]
    [int]$MaxJobs
)

# CSV Mode: process each server in the CSV by calling this script recursively
if ($PSCmdlet.ParameterSetName -eq 'CSV') {
    if (-not (Test-Path $CSVPath)) {
        Write-Host "CSV file not found: $CSVPath" -ForegroundColor Red
        exit 1
    }
    $csv = Import-Csv -Path $CSVPath
    # If Order column exists, sort by it (numeric), else process as is
    if ($csv | Get-Member -Name 'Order' -MemberType NoteProperty) {
        $csv = $csv | Sort-Object {[int]($_.Order)}
    }
    $jobsList = @()
    $jobCount = 0
    foreach ($row in $csv) {
        if (-not $row.ServerName -or -not $row.ResourceGroupName) {
            Write-Log "Error: Missing ServerName or ResourceGroupName in CSV row. Skipping this row." 'Error' -ToConsole
            continue
        }
        $params = @{
            ResourceGroupName = $row.ResourceGroupName
            ServerName = $row.ServerName
        }
        if ($row.MaximumDuration) { $params.MaximumDuration = $row.MaximumDuration }
        if ($row.RebootSetting) { $params.RebootSetting = $row.RebootSetting }
        if ($row.WindowsClassificationsToInclude) { $params.WindowsClassificationsToInclude = $row.WindowsClassificationsToInclude -split ',' }
        if ($row.LinuxClassificationsToInclude) { $params.LinuxClassificationsToInclude = $row.LinuxClassificationsToInclude -split ',' }
        $action = $row.Action
        if ($action -eq 'AssessOnly') {
            $params.AssessOnly = $true
        } elseif ($action -eq 'InstallOnly') {
            $params.InstallOnly = $true
        }
        $argList = @()
        foreach ($key in $params.Keys) {
            $value = $params[$key]
            if ($value -is [System.Collections.IEnumerable] -and -not ($value -is [string])) {
                foreach ($item in $value) { $argList += "-$key '$item'" }
            } elseif ($value -is [switch]) {
                if ($value) { $argList += "-$key" }
            } elseif ($null -ne $value -and $value -ne '') {
                $argList += "-$key '$value'"
            }
        }
        $argString = $argList -join ' '
        if ($Jobs) {
            # If MaxJobs is set, wait until number of running jobs is less than MaxJobs
            while ($MaxJobs -and ($jobsList | Where-Object { $_.State -eq 'Running' }).Count -ge $MaxJobs) {
                Start-Sleep -Seconds 2
            }
            $jobName = "PatchJob-$($row.ServerName)"
            Write-Log "Starting job: $jobName with args: $argString" 'Info' -ToConsole
            $job = Start-Job -Name $jobName -ScriptBlock {
                param($scriptPath, $args)
                & $scriptPath @args
            } -ArgumentList $PSCommandPath, $argList
            $jobsList += $job
        } else {
            Write-Log "Processing server $($row.ServerName) in resource group $($row.ResourceGroupName) with args: $argString" 'Info' -ToConsole
            & $PSCommandPath @argList
        }
    }
    # Monitor jobs if Jobs is set
    if ($Jobs -and $jobsList.Count -gt 0) {
        Write-Log "Waiting for all jobs to complete..." 'Info' -ToConsole
        while (($jobsList | Where-Object { $_.State -eq 'Running' }).Count -gt 0) {
            Start-Sleep -Seconds 5
        }
        $jobsList | Receive-Job -Wait | Out-Null
        Write-Log "All jobs completed." 'Info' -ToConsole
    }
    exit 0
}

# Ensure only one of -AssessOnly or -InstallOnly is specified
if ($AssessOnly -and $InstallOnly) {
    Write-Log "Error: Only one of -AssessOnly or -InstallOnly can be specified at a time." -ToConsole
    exit 1
}

function Write-Log {
    <#
    .SYNOPSIS
        Write a log entry to the log file and optionally to the console.
    .PARAMETER Message
        The log message.
    .PARAMETER Type
        The log type: Info, Warn, or Error.
    .PARAMETER ToConsole
        If set, also writes to the console.
    #>
    param (
        [string]$Message,
        [ValidateSet('Info','Warn','Error')][string]$Type = 'Info',
        [switch]$ToConsole
    )
    $timestamp = Get-Date -Format 'yyyy-MM-dd HH:mm:ss'
    $server = $env:COMPUTERNAME
    $logLine = "$timestamp $server $Type $Message"
    Add-Content -Path $LogFilePath -Value $logLine -Encoding UTF8
    if ($ToConsole) {
        switch ($Type) {
            'Error' { Write-Error $logLine }
            'Warn'  { Write-Warning $logLine }
            default { Write-Output $logLine }
        }
    }
}

# Ensure log directory exists
$logDir = Split-Path $LogFilePath -Parent
if (-not (Test-Path $logDir)) {
    New-Item -Path $logDir -ItemType Directory -Force | Out-Null
}

Write-Log "Script started by user: $([System.Security.Principal.WindowsIdentity]::GetCurrent().Name)" 'Info' -ToConsole

# Requires Az module
if (-not (Get-Module -ListAvailable -Name Az)) {
    Write-Log "Az module is not installed. Please install it using 'Install-Module -Name Az -Scope CurrentUser'." 'Error' -ToConsole
    exit 1
}

Import-Module Az
$azVersion = (Get-Module -Name Az | Select-Object -First 1).Version
Write-Log "Az PowerShell module version: $azVersion" 'Info' -ToConsole

# Check if the user is logged in to Azure, if not, prompt for login
try {
    $context = Get-AzContext
    if (-not $context) {
        Write-Log "Not logged in to Azure. Logging in..." 'Warn' -ToConsole
        Connect-AzAccount | Out-Null
        Write-Log "Login successful." 'Info' -ToConsole
    } else {
        Write-Log "Already logged in to Azure as $($context.Account)." 'Info' -ToConsole
    }
} catch {
    Write-Log "Not logged in to Azure. Logging in..." 'Warn' -ToConsole
    try {
        Connect-AzAccount | Out-Null
        Write-Log "Login successful." 'Info' -ToConsole
    } catch {
        Write-Log "Failed to log in to Azure. $_" 'Error' -ToConsole
        exit 1
    }
}

try {
    Write-Log "Checking if server '$ServerName' is an Azure VM or Azure Arc Connected Machine in resource group '$ResourceGroupName'..." 'Info' -ToConsole
    $vm = Get-AzVM -ResourceGroupName $ResourceGroupName -Name $ServerName -ErrorAction SilentlyContinue
    $arc = Get-AzConnectedMachine -ResourceGroupName $ResourceGroupName -Name $ServerName -ErrorAction SilentlyContinue

    if ($null -ne $vm) {
        $osType = $vm.StorageProfile.OSDisk.OSType
        $status = (Get-AzVM -ResourceGroupName $ResourceGroupName -Name $ServerName -Status).Statuses[1].DisplayStatus
        $msg = "[Azure VM] Name: $($vm.Name) | Location: $($vm.Location) | OS: $osType | Status: $status"
        Write-Log $msg 'Info' -ToConsole
        if (-not $InstallOnly) {
            Write-Log "Running patch assessment for Azure VM '$ServerName'..." 'Info' -ToConsole
            $assessment = Invoke-AzVMPatchAssessment -ResourceGroupName $ResourceGroupName -VMName $ServerName -ErrorAction SilentlyContinue
            Write-Log "Assessment output: $($assessment | Out-String)" 'Info' -ToConsole
        }
        if (-not $AssessOnly) {
            Write-Log "Installing patches on Azure VM '$ServerName'..." 'Info' -ToConsole
            if ($osType -eq 'Windows') {
                $install = Invoke-AzVMInstallPatch -ResourceGroupName $ResourceGroupName -VMName $ServerName -Windows -MaximumDuration $MaximumDuration -RebootSetting $RebootSetting -ClassificationToIncludeForWindows $WindowsClassificationsToInclude -ErrorAction SilentlyContinue
            } elseif ($osType -eq 'Linux') {
                $install = Invoke-AzVMInstallPatch -ResourceGroupName $ResourceGroupName -VMName $ServerName -Linux -MaximumDuration $MaximumDuration -RebootSetting $RebootSetting -ClassificationToIncludeForLinux $LinuxClassificationsToInclude -ErrorAction SilentlyContinue
            } else {
                Write-Log "Unknown OS type for VM '$ServerName'." 'Error' -ToConsole
                exit 1
            }
            if ($null -ne $install) {
                Write-Log "Install output: $($install | Out-String)" 'Info' -ToConsole
            }
        }
    } elseif ($null -ne $arc) {
        $osType = $arc.OsType
        $msg = "[Azure Arc] Name: $($arc.Name) | Location: $($arc.Location) | OS: $osType | Status: $($arc.Status)"
        Write-Log $msg 'Info' -ToConsole
        if (-not $InstallOnly) {
            Write-Log "Running patch assessment for Azure Arc Connected Machine '$ServerName'..." 'Info' -ToConsole
            $assessment = Invoke-AzConnectedAssessMachinePatch -ResourceGroupName $ResourceGroupName -Name $ServerName -ErrorAction SilentlyContinue
            Write-Log "Assessment output: $($assessment | Out-String)" 'Info' -ToConsole
        }
        if (-not $AssessOnly) {
            Write-Log "Installing patches on Azure Arc Connected Machine '$ServerName'..." 'Info' -ToConsole
            if ($osType -eq 'Windows') {
                $install = Install-AzConnectedMachinePatch -ResourceGroupName $ResourceGroupName -Name $ServerName -WindowParameterClassificationsToInclude $WindowsClassificationsToInclude -MaximumDuration $MaximumDuration -RebootSetting $RebootSetting -ErrorAction SilentlyContinue
            } elseif ($osType -eq 'Linux') {
                $install = Install-AzConnectedMachinePatch -ResourceGroupName $ResourceGroupName -Name $ServerName -LinuxParameterClassificationsToInclude $LinuxClassificationsToInclude -MaximumDuration $MaximumDuration -RebootSetting $RebootSetting -ErrorAction SilentlyContinue
            } else {
                Write-Log "Unknown OS type for Arc Connected Machine '$ServerName'." 'Warn' -ToConsole
            }
            if ($null -ne $install) {
                Write-Log "Install output: $($install | Out-String)" 'Info' -ToConsole
            }
        }
    } else {
        Write-Log "Server '$ServerName' not found as Azure VM or Azure Arc Connected Machine in resource group '$ResourceGroupName'." 'Warn' -ToConsole
        exit 1
    }
    Write-Log "Patch operation completed successfully for server '$ServerName'." 'Info'

} catch {
    Write-Log "Error checking/updating server '$ServerName': $($_.Exception.Message)" 'Error' -ToConsole
    Write-Log "Full error: $_" 'Error'
}
# End of script
