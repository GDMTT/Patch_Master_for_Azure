<#
.SYNOPSIS
    Export Azure VMs and Azure Arc connected machines to a timestamped CSV, either all or a specific server.

.DESCRIPTION
    - Ensures GGLIS folders (Logs, Backup, temp, cache) exist under C:\ProgramData\GGLIS
    - Connects to Azure if not already signed in
    - Retrieves Get-AzVM and Get-AzConnectedMachine
    - Supports either retrieving all servers with -All, or filtering by a server name with -ServerName
    - Logs progress and errors
    - Exports Name, ResourceGroupName, ServerType, OperatingSystem, Status, Size, Location, VirtualNetwork, Subnet to a CSV
    - If no matching servers are found when using -ServerName, writes "Not found" and exits without CSV

.PARAMETER All
    Switch to retrieve all Azure VMs and Arc machines. Cannot be used with -ServerName.

.PARAMETER ServerName
    Name of servers (VM or Arc) to filter by. Cannot be used with -All.

.PARAMETER OutputDirectory
    Folder to write the CSV into.
    Default: "$env:USERPROFILE\git-cache\data"

.PARAMETER LogDirectory
    Folder to write logs into.
    Default: "C:\ProgramData\GGLIS\Logs"

.EXAMPLE
    # Export all servers
    .\Get-AllAzMachines.ps1 -All

    # Export servers with name 'MyServer'
    .\Get-AllAzMachines.ps1 -ServerName "MyServer"
#>

[CmdletBinding(DefaultParameterSetName="AllServers")]
Param(
    [Parameter(Mandatory=$true, ParameterSetName="AllServers", Position=0)]
    [switch]$All,

    [Parameter(Mandatory=$true, ParameterSetName="ByName", Position=0)]
    [string]$ServerName,

    [Parameter(ParameterSetName="AllServers", Position=1)]
    [Parameter(ParameterSetName="ByName", Position=1)]
    [string]$OutputDirectory = "$($env:USERPROFILE)\git-cache\data",

    [Parameter(ParameterSetName="AllServers", Position=2)]
    [Parameter(ParameterSetName="ByName", Position=2)]
    [string]$LogDirectory    = "C:\ProgramData\GGLIS\Logs"
)

# Ensure required folders exist
$baseGGLIS = "C:\ProgramData\GGLIS"
foreach ($sub in @('Logs','Backup','temp','cache')) {
    $path = Join-Path $baseGGLIS $sub
    if (-not (Test-Path $path)) { New-Item -ItemType Directory -Path $path -Force | Out-Null }
}
if (-not (Test-Path $OutputDirectory)) { New-Item -ItemType Directory -Path $OutputDirectory -Force | Out-Null }

# Logging helper
function Write-Log {
    param([ValidateSet('Info','Warning','Error','Data')]$Type, $Message)
    $ts = Get-Date -Format 'yyyyMMdd HH-mm-ss'
    $ctx = Get-AzContext -ErrorAction SilentlyContinue
    $user = if ($ctx -and $ctx.Account.Id) { $ctx.Account.Id } else { $env:USERNAME }
    "$ts $user $Type $Message" | Out-File (Join-Path $LogDirectory 'Get-AllAzMachines.log') -Append -Encoding utf8
}
Write-Log Info '=== Starting Azure server CSV export ==='

# Ensure Azure login
try {
    Get-AzContext -ErrorAction Stop | Out-Null; Write-Log Data 'Azure context exists.'
} catch {
    Write-Log Info 'No Azure context: prompting login';
    Connect-AzAccount -ErrorAction Stop;
    Write-Log Info 'Logged into Azure.'
}

# Retrieve servers
$vms = @(); $arcs = @()
if ($PSCmdlet.ParameterSetName -eq 'ByName') {
    Write-Log Data "Filtering VMs by name '$ServerName'"
    $vms = Get-AzVM -ErrorAction Stop | Where-Object Name -eq $ServerName
    Write-Log Data "VMs found: $($vms.Count)"
    Write-Log Data "Filtering Arc machines by name '$ServerName'"
    $arcs = Get-AzConnectedMachine -ErrorAction Stop | Where-Object Name -eq $ServerName
    Write-Log Data "Arc machines found: $($arcs.Count)"
} else {
    Write-Log Data 'Retrieving all VMs'
    $vms = Get-AzVM -ErrorAction Stop
    Write-Log Data "VMs count: $($vms.Count)"
    Write-Log Data 'Retrieving all Arc machines'
    $arcs = Get-AzConnectedMachine -ErrorAction Stop
    Write-Log Data "Arc machines count: $($arcs.Count)"
}

# Accumulate details
$AllServers = @()
# Process VMs
foreach ($vm in $vms) {
    $detail = Get-AzVM -ResourceGroupName $vm.ResourceGroupName -Name $vm.Name -Status -ErrorAction Stop
    $power = ($detail.Statuses | Where-Object Code -like 'PowerState/*').DisplayStatus
    $os = $detail.StorageProfile.OSDisk.OSType
    $size = $detail.HardwareProfile.VmSize
    $loc = $detail.Location
    # Network info with null checks
    $vnet = ''; $subnet = ''
    if ($detail.NetworkProfile.NetworkInterfaces -and $detail.NetworkProfile.NetworkInterfaces.Count -gt 0) {
        $nicRef = $detail.NetworkProfile.NetworkInterfaces[0].Id
        $parts = $nicRef -split '/'
        $nicName = $parts[-1]; $nicRg = $parts[4]
        $nic = Get-AzNetworkInterface -Name $nicName -ResourceGroupName $nicRg -ErrorAction SilentlyContinue
        if ($nic -and $nic.IpConfigurations -and $nic.IpConfigurations.Count -gt 0 -and $nic.IpConfigurations[0].Subnet) {
            $subParts = $nic.IpConfigurations[0].Subnet.Id -split '/'
            $vnet = $subParts[-3]; $subnet = $subParts[-1]
        }
    }
    $AllServers += [PSCustomObject]@{
        ServerName        = $vm.Name
        ResourceGroupName = $vm.ResourceGroupName
        ServerType        = 'VM'
        OperatingSystem   = $os
        Status            = $power
        Size              = $size
        Location          = $loc
        VirtualNetwork    = $vnet
        Subnet            = $subnet
    }
}
# Process Arc machines
foreach ($arc in $arcs) {
    $os = $arc.OSType
    $status = $arc.ConnectionState
    $loc = $arc.Location
    $AllServers += [PSCustomObject]@{
        ServerName        = $arc.Name
        ResourceGroupName = $arc.ResourceGroupName
        ServerType        = 'Arc'
        OperatingSystem   = $os
        Status            = $status
        Size              = ''
        Location          = $loc
        VirtualNetwork    = ''
        Subnet            = ''
    }
}

# Handle no results for ServerName filter
if ($PSCmdlet.ParameterSetName -eq 'ByName' -and $AllServers.Count -eq 0) {
    Write-Host 'Not found'
    Write-Log Info "No matching servers found for '$ServerName'"
    exit 0
}

# Export CSV
$stamp = Get-Date -Format 'yy_MM_dd_HH-mm'
$outFile = Join-Path $OutputDirectory "AzureServers_$stamp.csv"
Write-Log Data "Exporting to CSV > $outFile"
$AllServers |
    Select ServerName, ResourceGroupName, ServerType, OperatingSystem, Status, Size, Location, VirtualNetwork, Subnet |
    Export-Csv -Path $outFile -NoTypeInformation -Encoding utf8
Write-Log Info "Export complete > $outFile"
Write-Output $outFile
Write-Log Info '=== Finished Azure server CSV export ==='
