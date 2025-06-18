param (
    [Parameter(Mandatory=$true)]
    [string]$ResourceGroupName,
    [string]$LogFilePath = $(Join-Path -Path 'C:\programfiles\GDMTT\Logs' -ChildPath ("Invoke-PatchAzureMachines-$(Get-Date -Format 'yyyyMMdd').log"))
)

function Write-Log {
    param (
        [string]$Message,
        [ValidateSet('Info','Warn','Error')][string]$Type = 'Info'
    )
    $timestamp = Get-Date -Format 'yyyy-MM-dd HH:mm:ss'
    $server = $env:COMPUTERNAME
    $logLine = "$timestamp $server $Type $Message"
    Add-Content -Path $LogFilePath -Value $logLine
    Write-Host $logLine
}

# Ensure log directory exists
$logDir = Split-Path $LogFilePath -Parent
if (-not (Test-Path $logDir)) {
    New-Item -Path $logDir -ItemType Directory -Force | Out-Null
}

Write-Log "Script started by user: $([System.Security.Principal.WindowsIdentity]::GetCurrent().Name)" 'Info'

# Requires Az module
if (-not (Get-Module -ListAvailable -Name Az)) {
    Write-Log "Az module is not installed. Please install it using 'Install-Module -Name Az -Scope CurrentUser'." 'Error'
    Write-Error "Az module is not installed. Please install it using 'Install-Module -Name Az -Scope CurrentUser'."
    exit 1
}

Import-Module Az
$azVersion = (Get-Module -Name Az | Select-Object -First 1).Version
Write-Log "Az PowerShell module version: $azVersion" 'Info'

# Check if the user is logged in to Azure, if not, prompt for login
try {
    $context = Get-AzContext
    if (-not $context) {
        Write-Log "Not logged in to Azure. Logging in..." 'Warn'
        Connect-AzAccount | Out-Null
        Write-Log "Login successful." 'Info'
    } else {
        Write-Log "Already logged in to Azure as $($context.Account)." 'Info'
    }
} catch {
    Write-Log "Not logged in to Azure. Logging in..." 'Warn'
    try {
        Connect-AzAccount | Out-Null
        Write-Log "Login successful." 'Info'
    } catch {
        Write-Log "Failed to log in to Azure. $_" 'Error'
        Write-Error "Failed to log in to Azure. $_"
        exit 1
    }
}

try {
    Write-Log "Retrieving Azure VMs in resource group '$ResourceGroupName'..." 'Info'
    $vms = Get-AzVM -ResourceGroupName $ResourceGroupName
    if ($vms.Count -eq 0) {
        Write-Log "No Azure VMs found in resource group '$ResourceGroupName'." 'Warn'
        Write-Output "No Azure VMs found in resource group '$ResourceGroupName'."
    } else {
        foreach ($vm in $vms) {
            $status = (Get-AzVM -ResourceGroupName $ResourceGroupName -Name $vm.Name -Status).Statuses[1].DisplayStatus
            $msg = "VM Name: $($vm.Name) | Location: $($vm.Location) | Status: $status"
            Write-Log $msg 'Info'
            Write-Output $msg
        }
    }
} catch {
    Write-Log "Error retrieving Azure VMs: $($_.Exception.Message)" 'Error'
    Write-Log "Full error: $_" 'Error'
    Write-Error "Error retrieving Azure VMs: $($_.Exception.Message)"
    Write-Error $_
}
# End of script
