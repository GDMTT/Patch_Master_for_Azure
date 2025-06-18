<#
.SYNOPSIS
    Check for and install updates on Azure VMs or Azure Arc machines (Windows or Linux).

.DESCRIPTION
    Three modes via ParameterSets:
      • OneShot  : single server (–CheckOnly / –InstallOnly)
      • Serial   : CSV, one row at a time
      • Parallel : CSV + jobs switch (spawns one child script per row)
    Uses Az.Compute & Az.ConnectedMachine modules.
    Logs to C:\ProgramData\GGLIS\Logs, reports to user’s git-cache\data,
    auto-creates Backup/temp/cache under C:\ProgramData\GGLIS,
    exposes RebootSetting, MaximumDuration, and WindowsClassificationsToInclude.
#>
[CmdletBinding(DefaultParameterSetName='OneShot')]
Param(
    # OneShot only
    [Parameter(Mandatory=$true,Position=0,ParameterSetName='OneShot')]
    [string] $ServerName,
    [Parameter(Mandatory=$true,ParameterSetName='OneShot')]
    [string] $ResourceGroupName,
    [Parameter(ParameterSetName='OneShot')]
    [switch] $CheckOnly,
    [Parameter(ParameterSetName='OneShot')]
    [switch] $InstallOnly,

    # Serial & Parallel share CsvPath
    [Parameter(Mandatory=$true,ParameterSetName='Serial')]
    [Parameter(Mandatory=$true,ParameterSetName='Parallel')]
    [string] $CsvPath,

    # Parallel only
    [Parameter(Mandatory=$true,ParameterSetName='Parallel')]
    [switch] $Jobs,
    [Parameter(ParameterSetName='Parallel')]
    [int] $JobWatch = 30,

    # Patch behavior
    [Parameter()]
    [ValidateSet('IfRequired','Always','Never','NoReboot')]
    [string] $RebootSetting = 'IfRequired',
    [Parameter()]
    [ValidateSet('PT1H','PT2H','PT3H','PT4H')]
    [string] $MaximumDuration = 'PT1H',
    [Parameter()]
    [string[]] $WindowsClassificationsToInclude = @(
        'Critical','Security','UpdateRollup','FeaturePack','ServicePack','Definition','Tools','Updates'
    )
)

# Save script path and ensure Az modules are loaded
$ScriptFile = $MyInvocation.MyCommand.Definition
Import-Module Az.Accounts -ErrorAction Stop
Import-Module Az.Compute -ErrorAction Stop
Import-Module Az.ConnectedMachine -ErrorAction Stop
# capture current Azure context for use in jobs
$AzContext = Get-AzContext

### — Setup folders & log file
$basePath = 'C:\ProgramData\GGLIS'
foreach ($sub in 'Logs','Backup','temp','cache') {
    $d = Join-Path -Path $basePath -ChildPath $sub
    if (-not (Test-Path $d)) { New-Item -Path $d -ItemType Directory -Force | Out-Null }
}
$userCache = "C:\Users\$($env:USERNAME)\git-cache\data"
if (-not (Test-Path $userCache)) { New-Item -Path $userCache -ItemType Directory -Force | Out-Null }

$ts      = (Get-Date).ToString('yyyy_MM_dd_HH-mm')
$logDir  = Join-Path -Path $basePath -ChildPath 'Logs'
$logFile = Join-Path -Path $logDir -ChildPath "GGLIS_Update_$ts.log"
New-Item -Path $logFile -ItemType File -Force | Out-Null

function Write-Log {
    Param(
        [ValidateSet('Info','Warning','Error','Data')] [string] $Level,
        [string] $Message
    )
    $t = Get-Date -Format 'yyyyMMdd HHmmss'
    try { $u = (Get-ADUser -Identity $env:USERNAME -ErrorAction Stop).UserPrincipalName } catch { $u = $env:USERNAME }
    $entry = "$t $u $Level $Message"
    Add-Content -Path $logFile -Value $entry
    Write-Host "[$Level] $Message"
}

### — Counters
$global:Total      = 0
$global:Checks     = 0
$global:Installs   = 0
$global:CheckErr   = @()
$global:InstallErr = @()

### — Core logic
function Invoke-Update {
    Param(
        [string] $Name,
        [string] $RG,
        [ValidateSet('CheckOnly','InstallOnly','Both')] [string] $Action
    )

    $global:Total++
    Write-Log Info "[Detect] $Name in $RG"

    # Detect VM vs Arc
    $isVm = $false
    try {
        $vm = Get-AzVM -Name $Name -ResourceGroupName $RG -Status -ErrorAction Stop
        $isVm = $true
    } catch {
        if ($_.Exception.Message -notmatch 'not found') {
            Write-Log Error "[DetectError] $($_.Exception.Message)"
            return
        }
    }
    if (-not $isVm) {
        try { Get-AzConnectedMachine -Name $Name -ResourceGroupName $RG -ErrorAction Stop | Out-Null } 
        catch { Write-Log Error "[NotFound] $Name not found as VM or Arc"; return }
    }

    # Assessment
    if ($Action -in 'Both','CheckOnly') {
        if ($isVm) {
            Write-Log Info "[Assess] VM $Name"
            try {
                $a   = Invoke-AzVMPatchAssessment -ResourceGroupName $RG -VMName $Name -ErrorAction Stop
                $out = $a | Out-String -Width 4096
                Write-Log Data "[AssessmentOutput] $out"
                Write-Host $out
                $global:Checks++
            } catch {
                $msg  = $_.Exception.Message; $full = $_.Exception | Out-String
                Write-Log Error "[AssessFailed] VM $Name → $msg"
                Write-Log Error "[AssessFull] VM $Name → $full"
                $global:CheckErr += $Name
            }
        } else {
            Write-Log Info "[Assess] Arc $Name"
            try {
                $a   = Invoke-AzConnectedAssessMachinePatch -ResourceGroupName $RG -Name $Name -ErrorAction Stop
                $out = $a | Out-String -Width 4096
                Write-Log Data "[AssessmentOutput] $out"
                Write-Host $out
                $global:Checks++
            } catch {
                $msg  = $_.Exception.Message; $full = $_.Exception | Out-String
                Write-Log Error "[AssessFailed] Arc $Name → $msg"
                Write-Log Error "[AssessFull] Arc $Name → $full"
                $global:CheckErr += $Name
            }
        }
    }

    # Install
    if ($Action -in 'Both','InstallOnly') {
        if ($isVm) {
            Write-Log Info "[Install] VM $Name"
            try {
                $p = @{ResourceGroupName=$RG;VmName=$Name;RebootSetting=$RebootSetting;MaximumDuration=$MaximumDuration;ClassificationsToInclude=$WindowsClassificationsToInclude;ErrorAction='Stop'}
                if ($vm.StorageProfile.OsDisk.OsType -eq 'Windows') { $p.Windows=$true } else { $p.Linux=$true }
                $i   = Invoke-AzVmInstallPatch @p
                $out = $i | Out-String -Width 4096
                Write-Log Data "[InstallOutput] $out"
                Write-Host $out
                $global:Installs++
            } catch {
                $msg  = $_.Exception.Message; $full = $_.Exception | Out-String
                Write-Log Error "[InstallFailed] VM $Name → $msg"
                Write-Log Error "[InstallFull] VM $Name → $full"
                $global:InstallErr += $Name
            }
        } else {
            Write-Log Info "[Install] Arc $Name"
            try {
                $i = Install-AzConnectedMachinePatch `
                    -ResourceGroupName $RG `
                    -Name $Name `
                    -RebootSetting $RebootSetting `
                    -MaximumDuration $MaximumDuration `
                    -WindowParameterClassificationsToInclude $WindowsClassificationsToInclude `
                    -ErrorAction Stop
                $out = $i | Out-String -Width 4096
                Write-Log Data "[InstallOutput] $out"
                Write-Host $out
                $global:Installs++
            } catch {
                $msg  = $_.Exception.Message; $full = $_.Exception | Out-String
                Write-Log Error "[InstallFailed] Arc $Name → $msg"
                Write-Log Error "[InstallFull] Arc $Name → $full"
                $global:InstallErr += $Name
            }
        }
    }

    Write-Log Info "[Done] $Name"
}

### — Dispatch by ParameterSet
switch ($PSCmdlet.ParameterSetName) {
    'OneShot' {
        $action = if ($CheckOnly) {'CheckOnly'} elseif ($InstallOnly) {'InstallOnly'} else {'Both'}
        Invoke-Update -Name $ServerName -RG $ResourceGroupName -Action $action
    }
    'Serial' {
        Import-Csv -Path $CsvPath | ForEach-Object {
            $launch = Get-Date "$($_.LaunchDate) $($_.LaunchTime)"
            while ((Get-Date) -lt $launch) { Start-Sleep -Seconds 15 }
            Invoke-Update -Name $_.Name -RG $_.ResourceGroup -Action $_.Action
        }
    }
    'Parallel' {
        # ensure modules and context are available
        Import-Module Az.Accounts -ErrorAction Stop
        Import-Module Az.Compute -ErrorAction Stop
        Import-Module Az.ConnectedMachine -ErrorAction Stop

        $csv = Import-Csv -Path $CsvPath
        foreach ($row in $csv) {
            # Determine correct RG field
            $rgValue = if ($row.PSObject.Properties['ResourceGroupName']) { $row.ResourceGroupName } else { $row.ResourceGroup }
            $job = Start-Job -Name "Upd_$($row.Name)" -ArgumentList @(
                $ScriptFile,
                $row.Name,
                $row.ResourceGroup,
                $row.Action,
                $RebootSetting,
                $MaximumDuration,
                ($WindowsClassificationsToInclude -join ','),
                $AzContext
            ) -ScriptBlock {
                param(
                    [string] $scriptFile,
                    [string] $name,
                    [string] $rg,
                    [string] $action,
                    [string] $reboot,
                    [string] $maxDur,
                    [string] $classificationsCsv,
                    [object] $ctx
                )
                Import-Module Az.Accounts -ErrorAction Stop
                Import-Module Az.Compute -ErrorAction Stop
                Import-Module Az.ConnectedMachine -ErrorAction Stop
                Set-AzContext -Context $ctx | Out-Null

                $classifications = $classificationsCsv -split ','
                & $scriptFile `
                    -ServerName $name `
                    -ResourceGroupName $rg `
                    -CheckOnly:($action -eq 'CheckOnly') `
                    -InstallOnly:($action -eq 'InstallOnly') `
                    -RebootSetting $reboot `
                    -MaximumDuration $maxDur `
                    -WindowsClassificationsToInclude $classifications
            }
            $job | Out-Null
        }

        # monitor and collect
        while (Get-Job -State Running) {
            Start-Sleep -Seconds $JobWatch
            Write-Host "Jobs remaining $((Get-Job -State Running).Count) waiting"
        }
        Get-Job | Receive-Job | Out-Null
        Get-Job | Remove-Job | Out-Null
    }
    default { throw "Unknown parameter set $($PSCmdlet.ParameterSetName)" }
}

### — Final report
$failures = ($global:CheckErr + $global:InstallErr | Select-Object -Unique)
$report   = @"
Report at      $(Get-Date)
Total servers  $($global:Total)
Checks done    $($global:Checks)
Installs done  $($global:Installs)
Check errors   $($global:CheckErr.Count)    $($global:CheckErr -join ', ')
Install errors $($global:InstallErr.Count)  $($global:InstallErr -join ', ')
Total failures $($failures.Count)
"@
$outPath = Join-Path -Path $userCache -ChildPath "UpdateReport_$ts.txt"
$report | Out-File -FilePath $outPath -Encoding UTF8
Write-Log Data "Report written to $outPath"
Write-Host $report
