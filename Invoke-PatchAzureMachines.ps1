param (
    [Parameter(Mandatory=$true)]
    [string]$ResourceGroupName,
    [Parameter(Mandatory=$true)]
    [string]$ServerName,
    [switch]$AssessOnly,
    [switch]$InstallOnly,
    [string]$MaximumDuration = 'PT1H',
    [string]$RebootSetting = 'IfRequired',
    [ValidateSet("Critical","Security","UpdateRollup","ServicePack","Definition","Updates","FeaturePack","Tools")][string[]]$WindowsClassificationsToInclude = @("Critical","Security","UpdateRollup","ServicePack","Definition","Updates"),
    [ValidateSet("Critical","Security","other")][string[]]$LinuxClassificationsToInclude = @("Critical","Security"),
    [string]$LogFilePath = $(Join-Path -Path 'C:\programfiles\GDMTT\Logs' -ChildPath ("Invoke-PatchAzureMachines-$(Get-Date -Format 'yyyyMMdd').log"))
)

function Write-Log {
    param (
        [string]$Message,
        [ValidateSet('Info','Warn','Error')][string]$Type = 'Info',
        [switch]$ToConsole
    )
    $timestamp = Get-Date -Format 'yyyy-MM-dd HH:mm:ss'
    $server = $env:COMPUTERNAME
    $logLine = "$timestamp $server $Type $Message"
    Add-Content -Path $LogFilePath -Value $logLine
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
                Write-Log "Unknown OS type for VM '$ServerName'." 'Warn' -ToConsole
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
                $install = Install-AzConnectedMachinePatch -ResourceGroupName $ResourceGroupName -Name $ServerName -Windows -WindowParameterClassificationsToInclude $WindowsClassificationsToInclude -MaximumDuration $MaximumDuration -RebootSetting $RebootSetting -ErrorAction SilentlyContinue
            } elseif ($osType -eq 'Linux') {
                $install = Install-AzConnectedMachinePatch -ResourceGroupName $ResourceGroupName -Name $ServerName -Linux -LinuxParameterClassificationsToInclude $LinuxClassificationsToInclude -MaximumDuration $MaximumDuration -RebootSetting $RebootSetting -ErrorAction SilentlyContinue
            } else {
                Write-Log "Unknown OS type for Arc Connected Machine '$ServerName'." 'Warn' -ToConsole
            }
            if ($null -ne $install) {
                Write-Log "Install output: $($install | Out-String)" 'Info' -ToConsole
            }
        }
    } else {
        Write-Log "Server '$ServerName' not found as Azure VM or Azure Arc Connected Machine in resource group '$ResourceGroupName'." 'Warn' -ToConsole
    }
} catch {
    Write-Log "Error checking/updating server '$ServerName': $($_.Exception.Message)" 'Error' -ToConsole
    Write-Log "Full error: $_" 'Error'
}
# End of script
