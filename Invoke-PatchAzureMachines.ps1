param (
    [Parameter(Mandatory=$true)]
    [string]$ResourceGroupName,
    [string]$ServerName,
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
        $status = (Get-AzVM -ResourceGroupName $ResourceGroupName -Name $ServerName -Status).Statuses[1].DisplayStatus
        $msg = "[Azure VM] Name: $($vm.Name) | Location: $($vm.Location) | Status: $status"
        Write-Log $msg 'Info' -ToConsole
        # Place update logic for Azure VM here
    } elseif ($null -ne $arc) {
        $msg = "[Azure Arc] Name: $($arc.Name) | Location: $($arc.Location) | OS: $($arc.OsType) | Status: $($arc.Status)"
        Write-Log $msg 'Info' -ToConsole
        # Place update logic for Azure Arc Connected Machine here
    } else {
        Write-Log "Server '$ServerName' not found as Azure VM or Azure Arc Connected Machine in resource group '$ResourceGroupName'." 'Warn' -ToConsole
    }
} catch {
    Write-Log "Error checking server '$ServerName': $($_.Exception.Message)" 'Error' -ToConsole
    Write-Log "Full error: $_" 'Error'
}
# End of script
