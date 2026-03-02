[CmdletBinding()]
param(
    [string]$BaseSetFile = "profiles/xauusd_v1_volatilitytrend_default.set",
    [string]$Symbol = "XAUUSD",
    [string]$Timeframe = "H1",
    [string]$Expert = "XAUUSD_V1_VolatilityTrend.ex5",
    [string]$ExpertLogPrefix = "XAUUSD_V1_VolatilityTrend",
    [string]$OutputLabel = "xauusd_v1_monthly_research",
    [switch]$CloseRunningTerminal,
    [switch]$RunFinalDeterminism
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

function Resolve-AbsolutePath {
    param([Parameter(Mandatory = $true)][string]$PathValue)
    $resolved = Resolve-Path -Path $PathValue -ErrorAction Stop
    return $resolved.ProviderPath
}

function Read-SetFile {
    param([Parameter(Mandatory = $true)][string]$Path)
    $map = @{}
    if (-not (Test-Path -Path $Path -PathType Leaf)) {
        return $map
    }
    $lines = Get-Content -Path $Path -Encoding ASCII
    foreach ($lineRaw in $lines) {
        $line = $lineRaw.Trim()
        if ([string]::IsNullOrWhiteSpace($line) -or $line.StartsWith(";")) {
            continue
        }
        $parts = $line.Split("=", 2)
        if ($parts.Count -ne 2) {
            continue
        }
        $map[$parts[0].Trim()] = $parts[1].Trim()
    }
    return $map
}

function Clone-Map {
    param([hashtable]$Source)
    $dest = @{}
    foreach ($k in $Source.Keys) {
        $dest[$k] = $Source[$k]
    }
    return $dest
}

function Apply-Overlay {
    param(
        [hashtable]$Base,
        [hashtable]$Overlay
    )
    $m = Clone-Map -Source $Base
    foreach ($k in $Overlay.Keys) {
        $m[$k] = [string]$Overlay[$k]
    }
    return $m
}

function Write-SetFile {
    param(
        [Parameter(Mandatory = $true)][hashtable]$Map,
        [Parameter(Mandatory = $true)][string]$Path
    )
    $keys = $Map.Keys | Sort-Object
    $lines = New-Object System.Collections.Generic.List[string]
    foreach ($k in $keys) {
        $lines.Add("$k=$($Map[$k])")
    }
    Set-Content -Path $Path -Value $lines -Encoding ASCII
}

function To-Comparable {
    param([double]$Value, [double]$NanValue)
    if ([double]::IsNaN($Value)) { return $NanValue }
    return $Value
}

function Is-BetterCandidate {
    param($A, $B)
    if ($null -eq $B) { return $true }

    if ([int]$A.months_passed -ne [int]$B.months_passed) {
        return ([int]$A.months_passed -gt [int]$B.months_passed)
    }

    $aMedRatio = To-Comparable -Value ([double]$A.median_monthly_balance_ratio) -NanValue -1.0e9
    $bMedRatio = To-Comparable -Value ([double]$B.median_monthly_balance_ratio) -NanValue -1.0e9
    if ([Math]::Abs($aMedRatio - $bMedRatio) -gt 1.0e-9) {
        return ($aMedRatio -gt $bMedRatio)
    }

    $aWorstDd = To-Comparable -Value ([double]$A.worst_month_dd_pct) -NanValue 1.0e9
    $bWorstDd = To-Comparable -Value ([double]$B.worst_month_dd_pct) -NanValue 1.0e9
    if ([Math]::Abs($aWorstDd - $bWorstDd) -gt 1.0e-9) {
        return ($aWorstDd -lt $bWorstDd)
    }

    $aMedPf = To-Comparable -Value ([double]$A.median_monthly_pf) -NanValue -1.0e9
    $bMedPf = To-Comparable -Value ([double]$B.median_monthly_pf) -NanValue -1.0e9
    if ([Math]::Abs($aMedPf - $bMedPf) -gt 1.0e-9) {
        return ($aMedPf -gt $bMedPf)
    }

    return ([int]$A.total_monthly_trades -gt [int]$B.total_monthly_trades)
}

$repoRoot = Resolve-AbsolutePath -PathValue (Join-Path $PSScriptRoot "..")
$runScript = Resolve-AbsolutePath -PathValue (Join-Path $PSScriptRoot "run_mt5_backtest.ps1")
$validateScript = Resolve-AbsolutePath -PathValue (Join-Path $PSScriptRoot "validate_v1_monthly.ps1")
$baseSetAbs = Resolve-AbsolutePath -PathValue $BaseSetFile

$researchRoot = Join-Path $repoRoot (Join-Path "outputs\research" $OutputLabel)
$setsDir = Join-Path $researchRoot "sets"
$null = New-Item -Path $setsDir -ItemType Directory -Force

$baseMap = Read-SetFile -Path $baseSetAbs
$baseMap["InpMagic"] = "26022451"
$baseMap["InpOnePositionOnly"] = "true"
$baseMap["InpUseRegimeFilter"] = "true"
$baseMap["InpUseTrendSlopeFilter"] = "true"
$baseMap["InpUsePullbackEntry"] = "true"
$baseMap["InpUseBreakoutContinuation"] = "true"
$baseMap["InpUseFixedRRTarget"] = "true"
$baseMap["InpUsePartialClose"] = "true"
$baseMap["InpUseTrailingAfterBE"] = "true"
$baseMap["InpUseCooldownAfterLoss"] = "true"
$baseMap["InpUseMaxBarsInTrade"] = "true"
$baseMap["InpUseNewsFilter"] = "false"
$baseMap["InpMinTradesForScore"] = "20"

$stages = @(
    [ordered]@{
        name = "risk_exit"
        options = @(
            [ordered]@{ option_id = "rx01"; InpRiskPercent = "0.50"; InpATR_SL_Mult = "2.0"; InpTP_R_Mult = "2.0"; InpBreakEvenAtR = "0.9"; InpATR_Trail_Mult = "1.5" },
            [ordered]@{ option_id = "rx02"; InpRiskPercent = "0.75"; InpATR_SL_Mult = "2.2"; InpTP_R_Mult = "2.2"; InpBreakEvenAtR = "1.0"; InpATR_Trail_Mult = "1.8" },
            [ordered]@{ option_id = "rx03"; InpRiskPercent = "1.00"; InpATR_SL_Mult = "2.6"; InpTP_R_Mult = "2.6"; InpBreakEvenAtR = "1.2"; InpATR_Trail_Mult = "2.0" }
        )
    },
    [ordered]@{
        name = "regime"
        options = @(
            [ordered]@{ option_id = "rg01"; InpUseRegimeFilter = "false"; InpUseTrendSlopeFilter = "false" },
            [ordered]@{ option_id = "rg02"; InpUseRegimeFilter = "true"; InpRegimeAdxMin = "18.0"; InpRegimeAtrPctMin = "20.0"; InpRegimeAtrPctMax = "90.0"; InpUseTrendSlopeFilter = "true"; InpTrendSlopeMinAtr = "0.05" },
            [ordered]@{ option_id = "rg03"; InpUseRegimeFilter = "true"; InpRegimeAdxMin = "22.0"; InpRegimeAtrPctMin = "25.0"; InpRegimeAtrPctMax = "85.0"; InpUseTrendSlopeFilter = "true"; InpTrendSlopeMinAtr = "0.08" }
        )
    },
    [ordered]@{
        name = "entry_mix"
        options = @(
            [ordered]@{ option_id = "em01"; InpUsePullbackEntry = "true"; InpUseBreakoutContinuation = "false" },
            [ordered]@{ option_id = "em02"; InpUsePullbackEntry = "false"; InpUseBreakoutContinuation = "true" },
            [ordered]@{ option_id = "em03"; InpUsePullbackEntry = "true"; InpUseBreakoutContinuation = "true"; InpBreakoutBufferATR = "0.15" }
        )
    },
    [ordered]@{
        name = "session_cooldown"
        options = @(
            [ordered]@{ option_id = "sc01"; InpUseTimeFilter = "true"; InpStartHour = "0"; InpEndHour = "24"; InpUseCooldownAfterLoss = "false"; InpCooldownBarsAfterLoss = "0" },
            [ordered]@{ option_id = "sc02"; InpUseTimeFilter = "true"; InpStartHour = "6"; InpEndHour = "20"; InpUseCooldownAfterLoss = "true"; InpCooldownBarsAfterLoss = "2" },
            [ordered]@{ option_id = "sc03"; InpUseTimeFilter = "true"; InpStartHour = "7"; InpEndHour = "18"; InpUseCooldownAfterLoss = "true"; InpCooldownBarsAfterLoss = "3" },
            [ordered]@{ option_id = "sc04"; InpUseTimeFilter = "true"; InpStartHour = "8"; InpEndHour = "22"; InpUseCooldownAfterLoss = "true"; InpCooldownBarsAfterLoss = "4" }
        )
    },
    [ordered]@{
        name = "refine"
        options = @(
            [ordered]@{ option_id = "rf01"; InpPartialAtR = "1.2"; InpPartialPct = "40.0"; InpMaxBarsInTrade = "30" },
            [ordered]@{ option_id = "rf02"; InpPartialAtR = "1.3"; InpPartialPct = "40.0"; InpMaxBarsInTrade = "36" },
            [ordered]@{ option_id = "rf03"; InpPartialAtR = "1.4"; InpPartialPct = "50.0"; InpMaxBarsInTrade = "42" },
            [ordered]@{ option_id = "rf04"; InpPartialAtR = "1.5"; InpPartialPct = "50.0"; InpMaxBarsInTrade = "48" }
        )
    }
)

$candidateRows = New-Object System.Collections.Generic.List[object]
$chosenSteps = New-Object System.Collections.Generic.List[object]
$currentMap = Clone-Map -Source $baseMap
$globalBest = $null
$candidateIndex = 0

foreach ($stage in $stages) {
    $stageName = [string]$stage.name
    Write-Host ""
    Write-Host ("===== Stage: {0} =====" -f $stageName)

    $stageBest = $null

    foreach ($opt in $stage.options) {
        $candidateIndex++
        $caseId = "c{0:D3}" -f $candidateIndex
        $optionId = [string]$opt.option_id

        $overlay = @{}
        foreach ($k in $opt.Keys) {
            if ($k -eq "option_id") { continue }
            $overlay[$k] = [string]$opt[$k]
        }

        $candidateMap = Apply-Overlay -Base $currentMap -Overlay $overlay
        $setPath = Join-Path $setsDir ("{0}_{1}_{2}.set" -f $caseId, $stageName, $optionId)
        Write-SetFile -Map $candidateMap -Path $setPath

        $isRunLabel = "{0}_{1}_{2}_is" -f $OutputLabel, $stageName, $caseId
        $isOutputRel = Join-Path (Join-Path "outputs\research" $OutputLabel) ("is_{0}_{1}" -f $stageName, $caseId)

        $runParams = @{
            SetFile = $setPath
            Symbol = $Symbol
            Timeframe = $Timeframe
            Expert = $Expert
            ExpertLogPrefix = $ExpertLogPrefix
            FromDate = "2018.01.01"
            ToDate = "2024.12.31"
            Deposit = 10000
            Leverage = 100
            OutputRoot = $isOutputRel
            RunLabel = $isRunLabel
            SplitTag = "is"
        }
        if ($CloseRunningTerminal.IsPresent) { $runParams.CloseRunningTerminal = $true }

        Write-Host ("[{0}] IS run {1}" -f (Get-Date -Format "HH:mm:ss"), $isRunLabel)
        & $runScript @runParams

        $validationLabel = "{0}_{1}_{2}_val" -f $OutputLabel, $stageName, $caseId
        $valParams = @{
            SetFile = $setPath
            Symbol = $Symbol
            Timeframe = $Timeframe
            Expert = $Expert
            ExpertLogPrefix = $ExpertLogPrefix
            OutputLabel = $validationLabel
            Deposit = 10000
            Leverage = 100
            ObjectiveRatio = 1.8
            MonthlyPfMin = 1.75
            MonthlyDdMax = 20.0
            MonthlyTradesMin = 20
            MonthsPassMin = 8
            MonthsTradesMin = 10
            CatastrophicDdMax = 30.0
        }
        if ($CloseRunningTerminal.IsPresent) { $valParams.CloseRunningTerminal = $true }

        Write-Host ("[{0}] Monthly validation {1}" -f (Get-Date -Format "HH:mm:ss"), $validationLabel)
        & $validateScript @valParams

        $summaryPath = Join-Path $repoRoot (Join-Path (Join-Path "outputs\validation" $validationLabel) "validation_summary.json")
        if (-not (Test-Path -Path $summaryPath -PathType Leaf)) {
            Write-Warning "Validation summary missing for $caseId"
            continue
        }

        $summary = Get-Content -Path $summaryPath -Raw | ConvertFrom-Json
        $months = @($summary.months)
        $totalTrades = 0
        foreach ($m in $months) { $totalTrades += [int]$m.trades }

        $row = [pscustomobject]@{
            case_id = $caseId
            stage = $stageName
            option_id = $optionId
            set_file = $setPath
            validation_label = $validationLabel
            classification = [string]$summary.classification
            months_passed = [int]$summary.months_passed
            months_total = [int]$summary.months_total
            median_monthly_balance_ratio = [double]$summary.median_monthly_balance_ratio
            median_monthly_pf = [double]$summary.median_monthly_pf
            worst_month_dd_pct = [double]$summary.worst_month_dd_pct
            total_monthly_trades = $totalTrades
        }
        $candidateRows.Add($row)

        if (Is-BetterCandidate -A $row -B $stageBest) {
            $stageBest = $row
        }
        if (Is-BetterCandidate -A $row -B $globalBest) {
            $globalBest = $row
        }
    }

    if ($null -eq $stageBest) {
        throw "No valid candidate produced in stage $stageName"
    }

    $bestOverlaySet = Read-SetFile -Path ([string]$stageBest.set_file)
    $currentMap = Clone-Map -Source $bestOverlaySet

    $chosenSteps.Add([pscustomobject]@{
        stage = $stageName
        chosen_case_id = [string]$stageBest.case_id
        chosen_option_id = [string]$stageBest.option_id
        set_file = [string]$stageBest.set_file
        months_passed = [int]$stageBest.months_passed
        median_monthly_balance_ratio = [double]$stageBest.median_monthly_balance_ratio
        median_monthly_pf = [double]$stageBest.median_monthly_pf
        worst_month_dd_pct = [double]$stageBest.worst_month_dd_pct
        total_monthly_trades = [int]$stageBest.total_monthly_trades
        classification = [string]$stageBest.classification
    })

    Write-Host ("Stage best: {0} ({1}) months_passed={2} med_ratio={3}" -f [string]$stageBest.case_id, [string]$stageBest.option_id, [int]$stageBest.months_passed, [double]$stageBest.median_monthly_balance_ratio)
}

if ($null -eq $globalBest) {
    throw "No candidates evaluated successfully."
}

$finalSetPath = Join-Path $repoRoot "profiles\xauusd_v1_prod_monthly_v1.set"
Copy-Item -Path ([string]$globalBest.set_file) -Destination $finalSetPath -Force

$finalValidationLabel = "xauusd_v1_prod_monthly_v1_validation"
$finalValParams = @{
    SetFile = $finalSetPath
    Symbol = $Symbol
    Timeframe = $Timeframe
    Expert = $Expert
    ExpertLogPrefix = $ExpertLogPrefix
    OutputLabel = $finalValidationLabel
    Deposit = 10000
    Leverage = 100
    ObjectiveRatio = 1.8
    MonthlyPfMin = 1.75
    MonthlyDdMax = 20.0
    MonthlyTradesMin = 20
    MonthsPassMin = 8
    MonthsTradesMin = 10
    CatastrophicDdMax = 30.0
}
if ($CloseRunningTerminal.IsPresent) { $finalValParams.CloseRunningTerminal = $true }
if ($RunFinalDeterminism.IsPresent) { $finalValParams.RunDeterminism = $true }

Write-Host ""
Write-Host "Running final validation on promoted profile..."
& $validateScript @finalValParams

$finalSummaryPath = Join-Path $repoRoot (Join-Path (Join-Path "outputs\validation" $finalValidationLabel) "validation_summary.json")
$finalSummary = Get-Content -Path $finalSummaryPath -Raw | ConvertFrom-Json

$metaPath = Join-Path $repoRoot "profiles\xauusd_v1_prod_monthly_v1.meta.json"
$meta = [ordered]@{
    profile_id = "xauusd_v1_prod_monthly_v1"
    symbol = $Symbol
    timeframe = $Timeframe
    objective_monthly_balance_ratio = 1.8
    monthly_pf_min = 1.75
    monthly_dd_max_pct = 20.0
    monthly_min_trades = 20
    months_passed = [int]$finalSummary.months_passed
    months_total = [int]$finalSummary.months_total
    classification = [string]$finalSummary.classification
    notes = @(
        ("median_monthly_balance_ratio={0}" -f [double]$finalSummary.median_monthly_balance_ratio),
        ("median_monthly_pf={0}" -f [double]$finalSummary.median_monthly_pf),
        ("worst_month_dd_pct={0}" -f [double]$finalSummary.worst_month_dd_pct)
    )
    created_utc = (Get-Date).ToUniversalTime().ToString("o")
}
$meta | ConvertTo-Json -Depth 6 | Set-Content -Path $metaPath -Encoding ASCII

$candidateCsvPath = Join-Path $researchRoot "candidate_scores.csv"
$candidateJsonPath = Join-Path $researchRoot "candidate_scores.json"
$chosenStepsPath = Join-Path $researchRoot "chosen_steps.json"
$summaryPath = Join-Path $researchRoot "research_summary.json"

@($candidateRows) |
    Sort-Object @{ Expression = { [int]$_.months_passed }; Descending = $true },
                @{ Expression = { [double]$_.median_monthly_balance_ratio }; Descending = $true },
                @{ Expression = { [double]$_.worst_month_dd_pct }; Descending = $false },
                @{ Expression = { [double]$_.median_monthly_pf }; Descending = $true },
                @{ Expression = { [int]$_.total_monthly_trades }; Descending = $true } |
    Export-Csv -Path $candidateCsvPath -NoTypeInformation -Encoding ASCII

@($candidateRows) | ConvertTo-Json -Depth 6 | Set-Content -Path $candidateJsonPath -Encoding ASCII
@($chosenSteps) | ConvertTo-Json -Depth 6 | Set-Content -Path $chosenStepsPath -Encoding ASCII

$summaryObj = [ordered]@{
    output_label = $OutputLabel
    final_set = $finalSetPath
    final_meta = $metaPath
    final_validation_summary = $finalSummaryPath
    final_classification = [string]$finalSummary.classification
    final_months_passed = [int]$finalSummary.months_passed
    final_months_total = [int]$finalSummary.months_total
    candidate_scores_csv = $candidateCsvPath
    candidate_scores_json = $candidateJsonPath
    chosen_steps_json = $chosenStepsPath
    created_utc = (Get-Date).ToUniversalTime().ToString("o")
}
$summaryObj | ConvertTo-Json -Depth 6 | Set-Content -Path $summaryPath -Encoding ASCII

Write-Host ""
Write-Host "Research complete."
Write-Host (" Final classification : {0}" -f [string]$finalSummary.classification)
Write-Host (" Final months passed : {0}/{1}" -f [int]$finalSummary.months_passed, [int]$finalSummary.months_total)
Write-Host (" Candidate CSV       : {0}" -f $candidateCsvPath)
Write-Host (" Summary JSON        : {0}" -f $summaryPath)
