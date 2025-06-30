<#
.SYNOPSIS
    Assess and install patches on Azure VMs or Azure Arc Connected Machines, supporting single server or batch CSV processing (including parallel jobs).

.DESCRIPTION
    This script checks if a specified server is an Azure VM or Azure Arc Connected Machine, then performs patch assessment and/or installation using the appropriate Azure PowerShell commands. It supports both Windows and Linux OS types, allows classification filtering, and logs all actions and outputs. The script can process a single server or a batch of servers from a CSV file. When using a CSV, jobs can be run in parallel, each with a unique log file. Assessment and install results are written to separate CSV files, with all output properties as columns. The install CSV lists installed patch names in the Patches column.

.PARAMETER ResourceGroupName
    The name of the Azure Resource Group containing the server. Used in single server mode.

.PARAMETER ServerName
    The name of the Azure VM or Azure Arc Connected Machine to patch. Used in single server mode.

.PARAMETER AssessOnly
    If specified, only performs patch assessment (no installation). Cannot be used with InstallOnly.

.PARAMETER InstallOnly
    If specified, only installs patches (no assessment). Cannot be used with AssessOnly.

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
    The path to the log file. Defaults to C:\ProgramData\GDMTT\Logs\Invoke-PatchAzureMachines-<date>.log. In parallel CSV mode, each job gets a unique log file with Job<Number>_<ServerName> in the name.

.PARAMETER CSVPath
    Path to a CSV file containing server patching instructions. If specified, ResourceGroupName and ServerName cannot be used. The CSV columns are: Order, ServerName, ResourceGroupName, Action, MaximumDuration, RebootSetting, WindowsClassificationsToInclude, LinuxClassificationsToInclude.

.PARAMETER Jobs
    If specified with CSVPath, processes servers in parallel jobs. Each job has a unique log file.

.PARAMETER MaxJobs
    If specified with Jobs, limits the number of concurrent jobs to this value.

.EXAMPLE
    .\Invoke-PatchAzureMachines.ps1 -ResourceGroupName 'MyRG' -ServerName 'MyVM'

.EXAMPLE
    .\Invoke-PatchAzureMachines.ps1 -CSVPath .\servers.csv

.EXAMPLE
    .\Invoke-PatchAzureMachines.ps1 -CSVPath .\servers.csv -Jobs -MaxJobs 3

.OUTPUTS
    Assessment results: C:\ProgramData\GDMTT\Reporting\Invoke-PatchAzureMachines-Assessment.csv
    Install results:    C:\ProgramData\GDMTT\Reporting\Invoke-PatchAzureMachines-Install.csv
    Each CSV includes all output properties as columns. The install CSV lists installed patch names in the Patches column (semicolon-separated).

.NOTES
    Author: Your Name
    Date: 2025-06-29
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
    [ValidateSet("IfRequired","Always","Never")]
    [string]$RebootSetting = 'IfRequired', # Reboot setting for patching
    [Parameter(ParameterSetName='SingleServer')]
    [ValidateSet("Critical","Security","UpdateRollup","ServicePack","Definition","Updates","FeaturePack","Tools")][string[]]$WindowsClassificationsToInclude = @("Critical","Security","UpdateRollup","ServicePack","Definition","Updates"),
    [Parameter(ParameterSetName='SingleServer')]
    [ValidateSet("Critical","Security","other")][string[]]$LinuxClassificationsToInclude = @("Critical","Security"),
    [Parameter(ParameterSetName='SingleServer')]
    [string]$LogFilePath = $(Join-Path -Path 'C:\ProgramData\GDMTT\Logs' -ChildPath ("Invoke-PatchAzureMachines-$(Get-Date -Format 'yyyyMMdd').log")),

    [Parameter(Mandatory=$true, ParameterSetName='CSV')]
    [string]$CSVPath,

    [Parameter(ParameterSetName='CSV')]
    [switch]$Jobs,
    [Parameter(ParameterSetName='CSV')]
    [int]$MaxJobs
)

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

function Write-ResultToCsv {
    param(
        [Parameter(Mandatory=$true)]
        [object]$Result,
        [Parameter(Mandatory=$true)]
        [string]$ServerName,
        [Parameter(Mandatory=$true)]
        [string]$CsvPath
    )
    $timestamp = Get-Date -Format 'yyyy-MM-dd HH:mm:ss'

    function Flatten-Object {
        <#
        .SYNOPSIS
            Recursively flattens a PowerShell object (including nested objects and arrays) into a hashtable suitable for CSV output.
        .DESCRIPTION
            - Handles nested objects by prefixing property names (e.g., Parent.Child).
            - Handles arrays by joining values with semicolons.
            - Special-cases the 'Patches' property to output a semicolon-separated list of patch names.
            - Skips null objects and returns an empty hashtable.
        .PARAMETER Obj
            The object to flatten.
        .PARAMETER Prefix
            The prefix to prepend to property names (used for recursion).
        #>
        param([object]$Obj, [string]$Prefix = '')
        $result = @{}
        if ($null -eq $Obj) { return $result } # Return empty if object is null

        # Get all property names for the object (handles both standard and NoteProperty)
        $props = $Obj | Get-Member -MemberType Property, NoteProperty | Select-Object -ExpandProperty Name
        if (-not $props) {
            # Fallback: use all public properties from PSObject if Get-Member returns nothing
            $props = $Obj.PSObject.Properties | Where-Object { $_.MemberType -eq 'Property' -or $_.MemberType -eq 'NoteProperty' } | Select-Object -ExpandProperty Name
        }

        foreach ($name in $props) {
            $value = $Obj.$name
            # Build the column name, prefixing if this is a nested property
            $colName = if ($Prefix) { "$Prefix.$name" } else { $name }

            # Special handling for PatchInstallationDetail[]: output patch names as a semicolon-separated string
            if ($name -eq 'Patches' -and $value -is [System.Collections.IEnumerable] -and $value.Count -gt 0 -and ($value | Select-Object -First 1).PSObject.Properties['Name']) {
                # Extract the Name property from each patch object
                $patchNames = $value | ForEach-Object { $_.Name }
                $result[$colName] = $patchNames -join '; '
            }
            # If the value is an array (but not a string), join its elements with semicolons
            elseif ($value -is [System.Collections.IEnumerable] -and -not ($value -is [string])) {
                $result[$colName] = ($value -join '; ')
            }
            # If the value is a nested object, recursively flatten it and merge the results
            elseif ($value -is [pscustomobject]) {
                $nested = Flatten-Object -Obj $value -Prefix $colName
                foreach ($k in $nested.Keys) { $result[$k] = $nested[$k] }
            }
            # Otherwise, just add the value as-is
            else {
                $result[$colName] = $value
            }
        }
        return $result
    }

    $staticColumns = @('TimeStamp','ServerName')
    $rows = @()
    if ($null -eq $Result) {
        $rows += @{ TimeStamp = $timestamp; ServerName = $ServerName; Status = 'NoResult' }
    } elseif ($Result -is [System.Collections.IEnumerable] -and -not ($Result -is [string])) {
        foreach ($item in $Result) {
            $flat = Flatten-Object -Obj $item
            $flat['TimeStamp'] = $timestamp
            $flat['ServerName'] = $ServerName
            $rows += $flat
        }
    } else {
        $flat = Flatten-Object -Obj $Result
        $flat['TimeStamp'] = $timestamp
        $flat['ServerName'] = $ServerName
        $rows += $flat
    }

    # Build superset of all columns seen so far
    $fileExists = Test-Path $CsvPath
    $existingHeader = $null
    if ($fileExists) {
        $existingHeader = (Get-Content -Path $CsvPath -TotalCount 1)
        $existingColumns = $existingHeader -split ','
    } else {
        $existingColumns = @()
    }
    $allColumns = $staticColumns + ($rows | ForEach-Object { $_.Keys } | Select-Object -Unique | Where-Object { $_ -notin $staticColumns })
    if (-not $fileExists -or ($existingHeader -ne ($allColumns -join ','))) {
        $dir = Split-Path $CsvPath -Parent
        if (-not (Test-Path $dir)) { New-Item -Path $dir -ItemType Directory -Force | Out-Null }
        $header = $allColumns -join ','
        if ($fileExists) {
            $lines = Get-Content -Path $CsvPath
            $lines[0] = $header
            Set-Content -Path $CsvPath -Value $lines -Encoding UTF8
        } else {
            Add-Content -Path $CsvPath -Value $header -Encoding UTF8
        }
    }
    foreach ($row in $rows) {
        $values = foreach ($col in $allColumns) { ($row[$col] -replace '([\r\n,])', ' ') }
        $line = $values -join ','
        Add-Content -Path $CsvPath -Value $line -Encoding UTF8
    }
}

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
        # Skip rows missing required columns
        if (-not $row.ServerName -or -not $row.ResourceGroupName) {
            Write-Log "Error: Missing ServerName or ResourceGroupName in CSV row. Skipping this row." 'Error' -ToConsole
            continue
        }
        # Prepare parameters for each server
        $params = @{
            ResourceGroupName = $row.ResourceGroupName
            ServerName = $row.ServerName
        }
        # Only add parameters if the value is not null or empty
        if ($row.MaximumDuration) { $params.MaximumDuration = $row.MaximumDuration }
        if ($row.RebootSetting) { $params.RebootSetting = $row.RebootSetting }

        # Determine OS type using Get-AzVM (for Azure VMs only)
        $osType = $null
        try {
            $vmInfo = Get-AzVM -ResourceGroupName $row.ResourceGroupName -Name $row.ServerName -ErrorAction Stop
            if ($null -ne $vmInfo) {
                $osType = $vmInfo.StorageProfile.OSDisk.OSType
            }
        } catch {
            $osType = $null
        }

        if ($osType -eq 'Linux') {
            if ($row.LinuxClassificationsToInclude) { $params.LinuxClassificationsToInclude = $row.LinuxClassificationsToInclude -split ',' }
        } else {
            if ($row.WindowsClassificationsToInclude) { $params.WindowsClassificationsToInclude = $row.WindowsClassificationsToInclude -split ',' }
        }

        $action = $row.Action
        if ($action -eq 'AssessOnly') {
            $params.AssessOnly = $true
        } elseif ($action -eq 'InstallOnly') {
            $params.InstallOnly = $true
        }
        # Build parameter hashtable for recursive call
        $paramHash = @{
        }
        foreach ($key in $params.Keys) {
            $value = $params[$key]
            if ($null -eq $value -or $value -eq '') { continue }
            if ($value -is [boolean]) {
                if ($value) { $paramHash[$key] = $true }
            } else {
                $paramHash[$key] = $value
            }
        }
        if ($Jobs) {
            # In parallel mode, assign a unique log file for each job
            $jobCount++
            $jobName = "PatchJob-$jobCount-$($row.ServerName)"
            $logDir = Split-Path $LogFilePath -Parent
            if (-not (Test-Path $logDir)) { New-Item -Path $logDir -ItemType Directory -Force | Out-Null }
            $jobLogFile = Join-Path -Path $logDir -ChildPath ("Invoke-PatchAzureMachines-Job${jobCount}_$($row.ServerName)-$(Get-Date -Format 'yyyyMMdd').log")
            $paramHash['LogFilePath'] = $jobLogFile
            Write-Log "Starting job: $jobName with params: $($paramHash | Out-String) and log file: $jobLogFile" 'Info' -ToConsole
            $job = Start-Job -Name $jobName -ScriptBlock {
                param($scriptPath, $paramHash)
                & $scriptPath @paramHash
            } -ArgumentList $PSCommandPath, $paramHash
            $jobsList += $job
        } else {
            Write-Log "Processing server $($row.ServerName) in resource group $($row.ResourceGroupName) with params: $($paramHash | Out-String)" 'Info' -ToConsole
            & $PSCommandPath @paramHash
        }
    }
    # Monitor jobs if Jobs is set
    if ($Jobs -and $jobsList.Count -gt 0) {
        Write-Log "Waiting for all jobs to complete..." 'Info' -ToConsole
        while (($jobsList | Where-Object { $_.State -eq 'Running' }).Count -gt 0) {
            $runningJobs = $jobsList | Where-Object { $_.State -eq 'Running' }
            $remaining = $runningJobs.Count
            $statusList = $jobsList | ForEach-Object { "Name: $($_.Name), State: $($_.State)" }
            Write-Host ("Jobs remaining: $remaining")
            Write-Host ("Job status:")
            $statusList | ForEach-Object { Write-Host $_ }
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

# Ensure log directory exists
$logDir = Split-Path $LogFilePath -Parent
if (-not (Test-Path $logDir)) {
    New-Item -Path $logDir -ItemType Directory -Force | Out-Null
}

Write-Log "Script started by user: $([System.Security.Principal.WindowsIdentity]::GetCurrent().Name)" 'Info' -ToConsole

# Requires Az module
if (-not (Get-InstalledModule -Name Az)) {
    Write-Log "Az module is not installed. Please install it using 'Install-Module -Name Az -Scope CurrentUser'." 'Error' -ToConsole
    exit 1
}

#Import-Module Az -ErrorAction Stop | Out-Null # Import the Az module silently. lots of warnings can be ignored
#$azVersion = (Get-Module -Name Az | Select-Object -First 1).Version
#Write-Log "Az PowerShell module version: $azVersion" 'Info' -ToConsole

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
            # Log assessment result to Assessment CSV
            Write-ResultToCsv -Result $assessment -ServerName $ServerName -CsvPath 'C:\ProgramData\GDMTT\Reporting\Invoke-PatchAzureMachines-Assessment.csv'
            if ($assessment.Status -eq 'Succeeded') {
                if ($assessment.Error) {
                    Write-Log "Patch assessment succeeded for Azure VM '$ServerName' but with warning: $($assessment.Error)" 'Warn' -ToConsole
                } else {
                    Write-Log "Patch assessment succeeded for Azure VM '$ServerName'." 'Info' -ToConsole
                }
            } else {
                Write-Log "Patch assessment failed for Azure VM '$ServerName'. Status: $($assessment.Status)" 'Error' -ToConsole
            }
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
                # Log install result to Install CSV
                Write-ResultToCsv -Result $install -ServerName $ServerName -CsvPath 'C:\ProgramData\GDMTT\Reporting\Invoke-PatchAzureMachines-Install.csv'
                if ($install.Status -eq 'Succeeded') {
                    if ($install.Error) {
                        Write-Log "Patch install succeeded for Azure VM '$ServerName' but with warning: $($install.Error)" 'Warn' -ToConsole
                    } else {
                        Write-Log "Patch install succeeded for Azure VM '$ServerName'." 'Info' -ToConsole
                    }
                } else {
                    Write-Log "Patch install failed for Azure VM '$ServerName'. Status: $($install.Status)" 'Error' -ToConsole
                }
            }
        }
    } elseif ($null -ne $arc) {
        $osType = $arc.OsType
        $msg = "[Azure Arc] Name: $($arc.Name) | Location: $($arc.Location) | OS: $osType | Status: $($arc.Status)"
        Write-Log $msg 'Info' -ToConsole
        if (-not $InstallOnly) {
            # Run patch assessment for Azure Arc Connected Machine
            Write-Log "Running patch assessment for Azure Arc Connected Machine '$ServerName'..." 'Info' -ToConsole
            $assessment = Invoke-AzConnectedAssessMachinePatch -ResourceGroupName $ResourceGroupName -Name $ServerName -ErrorAction SilentlyContinue
            Write-Log "Assessment output: $($assessment | Out-String)" 'Info' -ToConsole
            # Log assessment result to Assessment CSV (writes all properties as columns)
            Write-ResultToCsv -Result $assessment -ServerName $ServerName -CsvPath 'C:\ProgramData\GDMTT\Reporting\Invoke-PatchAzureMachines-Assessment.csv'
            # Check assessment status and log accordingly
            if ($assessment.Status -eq 'Succeeded') {
                if ($assessment.Error) {
                    Write-Log "Patch assessment succeeded for Azure Arc Connected Machine '$ServerName' but with warning: $($assessment.Error)" 'Warn' -ToConsole
                } else {
                    Write-Log "Patch assessment succeeded for Azure Arc Connected Machine '$ServerName'." 'Info' -ToConsole
                }
            } else {
                Write-Log "Patch assessment failed for Azure Arc Connected Machine '$ServerName'. Status: $($assessment.Status)" 'Error' -ToConsole
            }
        }
        if (-not $AssessOnly) {
            # Run patch install for Azure Arc Connected Machine
            Write-Log "Installing patches on Azure Arc Connected Machine '$ServerName'..." 'Info' -ToConsole
            if ($osType -eq 'Windows') {
                # Windows Arc: install patches with Windows classifications
                $install = Install-AzConnectedMachinePatch -ResourceGroupName $ResourceGroupName -Name $ServerName -WindowParameterClassificationsToInclude $WindowsClassificationsToInclude -MaximumDuration $MaximumDuration -RebootSetting $RebootSetting -ErrorAction SilentlyContinue
            } elseif ($osType -eq 'Linux') {
                # Linux Arc: install patches with Linux classifications
                $install = Install-AzConnectedMachinePatch -ResourceGroupName $ResourceGroupName -Name $ServerName -LinuxParameterClassificationsToInclude $LinuxClassificationsToInclude -MaximumDuration $MaximumDuration -RebootSetting $RebootSetting -ErrorAction SilentlyContinue
            } else {
                Write-Log "Unknown OS type for Arc Connected Machine '$ServerName'." 'Warn' -ToConsole
            }
            if ($null -ne $install) {
                Write-Log "Install output: $($install | Out-String)" 'Info' -ToConsole
                # Log install result to Install CSV (writes all properties as columns, Patches column lists installed patch names)
                Write-ResultToCsv -Result $install -ServerName $ServerName -CsvPath 'C:\ProgramData\GDMTT\Reporting\Invoke-PatchAzureMachines-Install.csv'
                # Check install status and log accordingly
                if ($install.Status -eq 'Succeeded') {
                    if ($install.Error) {
                        Write-Log "Patch install succeeded for Azure Arc Connected Machine '$ServerName' but with warning: $($install.Error)" 'Warn' -ToConsole
                    } else {
                        Write-Log "Patch install succeeded for Azure Arc Connected Machine '$ServerName'." 'Info' -ToConsole
                    }
                } else {
                    Write-Log "Patch install failed for Azure Arc Connected Machine '$ServerName'. Status: $($install.Status)" 'Error' -ToConsole
                }
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
