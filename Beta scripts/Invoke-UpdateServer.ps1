<#
.SYNOPSIS
  Assess and install Windows updates on Azure VMs or Azure Arc servers.
  Supports manual or CSV-driven batch mode (Action: Check, Install, Both), with optional parallel jobs.

.PARAMETER ServerName
  Name of the server (manual mode).
.PARAMETER ResourceGroupName
  Name of the Azure Resource Group (manual mode).
.PARAMETER CsvPath
  Path to CSV (batch mode). CSV headers must include: Name, ResourceGroup, Type, Action, LaunchDate, LaunchTime.
  **LaunchDate** should be in **yyyy-MM-dd** format, and **LaunchTime** in **HH:mm** (24-hour).
.PARAMETER Arc
  Treat server as Azure Arc in manual mode.
.PARAMETER CheckOnly
  Only perform assessment in manual mode.
.PARAMETER InstallOnly
  Only perform installation in manual mode.
.PARAMETER Jobs
  Run CSV entries in parallel PowerShell jobs.
.PARAMETER Throttle
  Maximum concurrent jobs when using -Jobs. Default is 5.
.PARAMETER JobWatch
  Poll interval in minutes for job status updates. Default is 5.
.PARAMETER Delay
  Internal delay in seconds before operations (used for scheduled jobs).
#>
param(
    [Parameter(Mandatory,ParameterSetName='Manual')]
    [string]$ServerName,
    [Parameter(Mandatory,ParameterSetName='Manual')]
    [string]$ResourceGroupName,
    [Parameter(Mandatory,ParameterSetName='Csv')]
    [string]$CsvPath,
    [Parameter(ParameterSetName='Manual')]
    [switch]$Arc,
    [Parameter(ParameterSetName='Manual')]
    [switch]$CheckOnly,
    [Parameter(ParameterSetName='Manual')]
    [switch]$InstallOnly,
    [Parameter(ParameterSetName='Csv')]
    [switch]$Jobs,
    [Parameter(ParameterSetName='Csv')]
    [int]$Throttle = 5,
    [Parameter(ParameterSetName='Csv')]
    [int]$JobWatch = 5,
    [Parameter(ParameterSetName='Manual')]
    [int]$Delay = 0
)

# Ensure required directories exist
$baseDir = 'C:\ProgramData\GGLIS'
$dirs = 'Logs','cache','Backup','temp' | ForEach-Object { Join-Path $baseDir $_ }
foreach ($d in $dirs) { if (-not (Test-Path $d)) { New-Item -Path $d -ItemType Directory -Force | Out-Null } }

# Paths
$scriptPath = $MyInvocation.MyCommand.Path
$scriptFile = Split-Path $scriptPath -Leaf
$logDir     = Join-Path $baseDir 'Logs'
$cacheDir   = Join-Path $baseDir 'cache'
$backupDir  = Join-Path $baseDir 'Backup'
$tempDir    = Join-Path $baseDir 'temp'
$mainLog    = Join-Path $logDir "${scriptFile}_$(Get-Date -Format yyyyMMdd).log"

# Logging helper
function Write-Log {
    param(
        [string]$Message,
        [ValidateSet('Info','Warning','Error','Data')][string]$Level = 'Info'
    )
    $ts = Get-Date -Format 'yyyyMMdd HH:mm:ss'
    $ctx = Get-AzContext -ErrorAction SilentlyContinue
    $user = if ($ctx.Account) { $ctx.Account.Id } else { $env:USERNAME }
    "$ts $user $Level $Message" | Out-File -FilePath $mainLog -Append -Encoding utf8
}

# Load Azure modules and authenticate
if (-not (Get-Module -ListAvailable -Name Az.Compute)) { Install-Module Az.Compute -Scope CurrentUser -Force }
Import-Module Az.Compute -ErrorAction Stop
if ($Arc -or $PSCmdlet.ParameterSetName -eq 'Csv') {
    if (-not (Get-Module -ListAvailable -Name Az.ConnectedMachine)) { Install-Module Az.ConnectedMachine -Scope CurrentUser -Force }
    Import-Module Az.ConnectedMachine -ErrorAction Stop
}
if (-not (Get-AzContext)) { Connect-AzAccount -ErrorAction Stop }

# Function: Assess updates
function Assess {
    param(
        [string]$RG,
        [string]$Name,
        [bool]$IsArc,
        [int]$DelaySec
    )
    if ($DelaySec -gt 0) { Start-Sleep -Seconds $DelaySec }
    Write-Host "Checking for updates on $Name>"
    try {
        if ($IsArc) {
            $res = Invoke-AzConnectedAssessMachinePatch -ResourceGroupName $RG -Name $Name -ErrorAction Stop
        } else {
            $res = Invoke-AzVMPatchAssessment -ResourceGroupName $RG -VMName $Name -ErrorAction Stop
        }
    } catch {
        $err = $_.Exception.Message
        Write-Log "ERROR assessing $Name – $err" 'Error'
        $ts = Get-Date -Format 'yyyyMMdd_HHmmss'
        $srv = Join-Path $logDir "$Name`_check_error_$ts.log"
        "=== ERROR assessing $Name at $(Get-Date) ===" | Out-File $srv
        $err | Out-File $srv -Append
        return
    }
    # Cache JSON
    $ts = Get-Date -Format 'yyyyMMdd_HHmmss'
    $cache = Join-Path $cacheDir "$Name`_assessment_$ts.json"
    $res | ConvertTo-Json -Depth 4 | Out-File $cache -Encoding utf8
    Write-Log "Assessment cached: $cache" 'Data'
    # Per-server log
    $srvLog = Join-Path $logDir "$Name`_check_$ts.log"
    "=== Assessment on $Name at $(Get-Date) ===" | Out-File $srvLog
    $res | Out-String | Out-File $srvLog -Append
}

# Function: Install updates
function InstallP {
    param(
        [string]$RG,
        [string]$Name,
        [bool]$IsArc,
        [int]$DelaySec
    )
    if ($DelaySec -gt 0) { Start-Sleep -Seconds $DelaySec }
    Write-Host "Installing updates on $Name>"
    try {
        if ($IsArc) {
            $res = Install-AzConnectedMachinePatch \
                -ResourceGroupName $RG \
                -Name $Name \
                -MaximumDuration 'PT30M' \
                -RebootSetting IfRequired \
                -WindowParameterClassificationsToInclude 'Critical','Definition','Drivers','Security','ServicePacks','UpdateRollups','Updates' \
                -ErrorAction Stop
        } else {
            $res = Invoke-AzVmInstallPatch \
                -ResourceGroupName $RG \
                -VmName $Name \
                -Windows \
                -MaximumDuration 'PT30M' \
                -RebootSetting IfRequired \
                -ErrorAction Stop
        }
    } catch {
        $err = $_.Exception.Message
        Write-Log "ERROR installing $Name – $err" 'Error'
        $ts = Get-Date -Format 'yyyyMMdd_HHmmss'
        $srv = Join-Path $logDir "$Name`_install_error_$ts.log"
        "=== ERROR installing $Name at $(Get-Date) ===" | Out-File $srv
        $err | Out-File $srv -Append
        return
    }
    Write-Log "Installation completed: $Name" 'Info'
    # Per-server log
    $srvLog = Join-Path $logDir "$Name`_install_$ts.log"
    "=== Installation on $Name at $(Get-Date) ===" | Out-File $srvLog
    $res | Out-String | Out-File $srvLog -Append
}

# Main execution
if ($PSCmdlet.ParameterSetName -eq 'Csv') {
    Write-Host "Starting CSV batch>"
    if (-not (Test-Path $CsvPath)) { Write-Log "CSV missing: $CsvPath" 'Error'; exit 1 }
    Write-Log "Loading CSV: $CsvPath" 'Info'
    Copy-Item -Path $CsvPath -Destination $backupDir -Force
    Write-Log "CSV backed up to $backupDir" 'Data'

    $rows = Import-Csv -Path $CsvPath
    Write-Host "Entries: $($rows.Count)>"
    $jobIds = @()

    foreach ($row in $rows) {
        # Extract date/time
        $ld = ($row.LaunchDate -as [string]).Trim()
        $lt = ($row.LaunchTime -as [string]).Trim()
        $name = $row.Name; $rg = $row.ResourceGroup; $type = $row.Type.ToLower(); $act = $row.Action.ToLower()
        if ((($ld -and -not $lt) -or (-not $ld -and $lt))) {
            Write-Log "Skipping malformed row: $($row | Out-String)" 'Warning'
            Write-Host "Skipping $name> malformed>"; continue
        }
        if (-not $rg) {
            Write-Log "Skipping $name missing RG" 'Warning'
            Write-Host "Skipping $name> noRG>"; continue
        }
        $isArc = $type -eq 'arc'
        $delay = 0
        if ($ld -and $lt) {
            $dt = [datetime]::ParseExact("$ld $lt", 'yyyy-MM-dd HH:mm', $null)
            $delay = [math]::Max(0, ($dt - (Get-Date)).TotalSeconds)
        }
        Write-Host "Row $name ($act) delay=$delay>"

        if ($Jobs) {
            while ((Get-Job -State Running).Count -ge $Throttle) { Start-Sleep -Seconds 5 }
            $args = @('-ServerName',$name,'-ResourceGroupName',$rg,'-Delay',$delay)
            if ($isArc) { $args += '-Arc' }
            if ($act -eq 'check') { $args += '-CheckOnly' }
            elseif ($act -eq 'install') { $args += '-InstallOnly' }
            elseif ($act -eq 'both') { $args += '-CheckOnly','-InstallOnly' }
            $job = Start-Job -Name $name -FilePath $scriptPath -ArgumentList $args
            Write-Log "Scheduled job $($job.Id) for $name (delay=${delay}s)" 'Info'
            Write-Host "Job $($job.Id) for $name>"
            $jobIds += $job.Id
        } else {
            if ($delay -gt 0) { Start-Sleep -Seconds $delay }
            switch ($act) {
                'check'   { Assess -RG $rg -Name $name -IsArc $isArc -DelaySec 0 }
                'install' { InstallP -RG $rg -Name $name -IsArc $isArc -DelaySec 0 }
                'both'    { Assess -RG $rg -Name $name -IsArc $isArc -DelaySec 0; InstallP -RG $rg -Name $name -IsArc $isArc -DelaySec 0 }
            }
        }
    }

    if (-not $Jobs) { Write-Host 'Batch done>'; Write-Log 'Batch done' 'Info' }
    if ($Jobs -and $jobIds.Count) {
        do {
            Clear-Host
            Get-Job | Where-Object { $_.Id -in $jobIds } |
                Select-Object Id,Name,State,@{Name='Start';Expression={$_.PSBeginTime}},@{Name='Elapsed';Expression={(Get-Date)-$_.PSBeginTime}} |
                Format-Table -AutoSize
            Start-Sleep -Seconds ($JobWatch * 60)
        } until ((Get-Job | Where-Object { $_.Id -in $jobs -and $_.State -eq 'Running' }).Count -eq 0)
        Write-Host 'All jobs done>'; Write-Log 'All jobs done' 'Info'
    }
} else {
    Write-Host "Running manual $ServerName (Arc=$Arc)>"
    Write-Log "Manual run: $ServerName (Arc=$Arc)" 'Info'
    if (-not $InstallOnly) { Assess -RG $ResourceGroupName -Name $ServerName -IsArc $Arc -DelaySec $Delay }
    if (-not $CheckOnly)  { InstallP -RG $ResourceGroupName -Name $ServerName -IsArc $Arc -DelaySec $Delay }
    Write-Host 'Manual complete>'; Write-Log 'Manual complete' 'Info'
}
