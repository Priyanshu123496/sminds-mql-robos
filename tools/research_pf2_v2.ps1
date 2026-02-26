[CmdletBinding()]
param(
    [string]$BaseSetFile = "profiles/pf2_window_0607_v1.set",
    [string]$Symbol = "XAUUSD",
    [string]$Timeframe = "M15",
    [string]$OutputLabel = "pf2_window_0607_v2_research",
    [switch]$CloseRunningTerminal
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

function Resolve-AbsolutePath {
    param([Parameter(Mandatory = $true)][string]$PathValue)
    $resolved = Resolve-Path -Path $PathValue -ErrorAction Stop
    return $resolved.ProviderPath
}

function Copy-Hashtable {
    param([hashtable]$Source)
    $dest = @{}
    foreach ($key in $Source.Keys) {
        $dest[$key] = $Source[$key]
    }
    return $dest
}

function Read-SetFile {
    param([Parameter(Mandatory = $true)][string]$Path)
    $map = @{}
    $lines = Get-Content -Path $Path -Encoding ASCII
    foreach ($lineRaw in $lines) {
        $line = $lineRaw.Trim()
        if ([string]::IsNullOrWhiteSpace($line)) {
            continue
        }
        if ($line.StartsWith(";")) {
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

function Write-SetFile {
    param(
        [Parameter(Mandatory = $true)][hashtable]$Map,
        [Parameter(Mandatory = $true)][string]$Path
    )
    $orderedKeys = @(
        "SignalTF",
        "TrendTF",
        "RiskPerTradePct",
        "DonchianBars",
        "AtrPeriod",
        "BreakoutBufferATR",
        "AdxPeriod",
        "AdxMin",
        "EmaFast",
        "EmaSlow",
        "SL_ATR",
        "TP_ATR",
        "BE_Trigger_R",
        "TrailStart_R",
        "TrailATR",
        "MaxBarsInTrade",
        "UseNewsFilter",
        "NewsBlockBeforeMin",
        "NewsBlockAfterMin",
        "NewsCurrencies",
        "SessionStartServerHour",
        "SessionEndServerHour",
        "FridayFlatHour",
        "FridayFlatMinute",
        "MaxSpreadPoints",
        "CommissionPerLotRT",
        "EntryTriggerMode",
        "EnableGateDiagnostics",
        "DiagnosticsPrintIntervalBars",
        "MinTradesForScore",
        "MaxAtrToPricePct",
        "CooldownBarsAfterLoss",
        "CooldownBarsAfterWin",
        "RequireCrossingSignal",
        "UseTrendSlopeFilter",
        "MinTrendSlopeAtr",
        "UseVolatilityPercentileFilter",
        "VolatilityLookbackBars",
        "MaxAtrPercentile",
        "MinAtrPercentile",
        "UseReentryPullbackLock",
        "ReentryLockBars",
        "ReentryPullbackAtr",
        "UseBarCloseConfirmation",
        "MinBreakoutExcessAtr"
    )

    $lines = New-Object System.Collections.Generic.List[string]
    foreach ($key in $orderedKeys) {
        if ($Map.ContainsKey($key)) {
            $lines.Add("$key=$($Map[$key])")
        }
    }
    foreach ($extraKey in ($Map.Keys | Sort-Object)) {
        if ($orderedKeys -notcontains $extraKey) {
            $lines.Add("$extraKey=$($Map[$extraKey])")
        }
    }
    Set-Content -Path $Path -Value $lines -Encoding ASCII
}

function To-ComparableMetric {
    param([double]$Value, [double]$DefaultIfNan)
    if ([double]::IsNaN($Value)) {
        return $DefaultIfNan
    }
    return $Value
}

function Is-BetterCandidate {
    param(
        [Parameter(Mandatory = $true)]$Candidate,
        [Parameter(Mandatory = $false)]$Best
    )
    if ($null -eq $Best) {
        return $true
    }

    $candMedian = To-ComparableMetric -Value ([double]$Candidate.oos_median_pf) -DefaultIfNan -1.0e9
    $bestMedian = To-ComparableMetric -Value ([double]$Best.oos_median_pf) -DefaultIfNan -1.0e9
    if ($candMedian -gt $bestMedian + 1.0e-9) {
        return $true
    }
    if ([Math]::Abs($candMedian - $bestMedian) -gt 1.0e-9) {
        return $false
    }

    $candDd = To-ComparableMetric -Value ([double]$Candidate.oos_max_dd_pct) -DefaultIfNan 1.0e9
    $bestDd = To-ComparableMetric -Value ([double]$Best.oos_max_dd_pct) -DefaultIfNan 1.0e9
    if ($candDd + 1.0e-9 -lt $bestDd) {
        return $true
    }
    if ([Math]::Abs($candDd - $bestDd) -gt 1.0e-9) {
        return $false
    }

    $candTrades = [int]$Candidate.oos_trades
    $bestTrades = [int]$Best.oos_trades
    return ($candTrades -gt $bestTrades)
}

$repoRoot = Resolve-AbsolutePath -PathValue (Join-Path $PSScriptRoot "..")
$validateScript = Resolve-AbsolutePath -PathValue (Join-Path $PSScriptRoot "validate_profile.ps1")
$baseSetAbs = Resolve-AbsolutePath -PathValue $BaseSetFile

$researchRoot = Join-Path $repoRoot ("outputs\\research\\" + $OutputLabel)
$candidateSetDir = Join-Path $researchRoot "sets"
$null = New-Item -Path $candidateSetDir -ItemType Directory -Force

$baseMap = Read-SetFile -Path $baseSetAbs
$workingMap = Copy-Hashtable -Source $baseMap

$searchPlan = @(
    [ordered]@{
        name = "SessionWindow"
        options = @(
            [ordered]@{ SessionStartServerHour = "5"; SessionEndServerHour = "7"; option_id = "s0507" },
            [ordered]@{ SessionStartServerHour = "6"; SessionEndServerHour = "7"; option_id = "s0607" },
            [ordered]@{ SessionStartServerHour = "6"; SessionEndServerHour = "8"; option_id = "s0608" },
            [ordered]@{ SessionStartServerHour = "23"; SessionEndServerHour = "2"; option_id = "s2302" }
        )
    },
    [ordered]@{
        name = "BE_Trigger_R"
        options = @(
            [ordered]@{ BE_Trigger_R = "0.6"; option_id = "be06" },
            [ordered]@{ BE_Trigger_R = "0.7"; option_id = "be07" },
            [ordered]@{ BE_Trigger_R = "0.8"; option_id = "be08" }
        )
    },
    [ordered]@{
        name = "TrailStart_R"
        options = @(
            [ordered]@{ TrailStart_R = "0.9"; option_id = "ts09" },
            [ordered]@{ TrailStart_R = "1.0"; option_id = "ts10" },
            [ordered]@{ TrailStart_R = "1.1"; option_id = "ts11" }
        )
    },
    [ordered]@{
        name = "TrailATR"
        options = @(
            [ordered]@{ TrailATR = "0.9"; option_id = "ta09" },
            [ordered]@{ TrailATR = "1.0"; option_id = "ta10" },
            [ordered]@{ TrailATR = "1.1"; option_id = "ta11" }
        )
    },
    [ordered]@{
        name = "SL_ATR"
        options = @(
            [ordered]@{ SL_ATR = "1.4"; option_id = "sl14" },
            [ordered]@{ SL_ATR = "1.6"; option_id = "sl16" }
        )
    },
    [ordered]@{
        name = "TP_ATR"
        options = @(
            [ordered]@{ TP_ATR = "3.6"; option_id = "tp36" },
            [ordered]@{ TP_ATR = "4.8"; option_id = "tp48" }
        )
    },
    [ordered]@{
        name = "MaxAtrToPricePct"
        options = @(
            [ordered]@{ MaxAtrToPricePct = "0.40"; option_id = "max040" },
            [ordered]@{ MaxAtrToPricePct = "0.45"; option_id = "max045" },
            [ordered]@{ MaxAtrToPricePct = "0.50"; option_id = "max050" }
        )
    }
)

$candidateResults = New-Object System.Collections.Generic.List[object]
$chosenSteps = New-Object System.Collections.Generic.List[object]
$candidateIndex = 0

foreach ($dimension in $searchPlan) {
    Write-Host ""
    Write-Host ("Evaluating dimension: {0}" -f $dimension.name)

    $bestDim = $null
    foreach ($option in $dimension.options) {
        $candidateIndex++
        $candidateId = ("c{0:D3}_{1}_{2}" -f $candidateIndex, $dimension.name.ToLower(), $option.option_id)
        $candidateMap = Copy-Hashtable -Source $workingMap

        foreach ($key in $option.Keys) {
            if ($key -eq "option_id") {
                continue
            }
            $candidateMap[$key] = [string]$option[$key]
        }

        $setPath = Join-Path $candidateSetDir ($candidateId + ".set")
        Write-SetFile -Map $candidateMap -Path $setPath

        $validateLabel = ("{0}_{1}" -f $OutputLabel, $candidateId)
        $validateParams = @{
            SetFile = $setPath
            Symbol = $Symbol
            Timeframe = $Timeframe
            OutputLabel = $validateLabel
            SkipConfirmFolds = $true
        }
        if ($CloseRunningTerminal.IsPresent) {
            $validateParams.CloseRunningTerminal = $true
        }

        & $validateScript @validateParams

        $summaryPath = Join-Path $repoRoot ("outputs\\validation\\{0}\\validation_summary.json" -f $validateLabel)
        if (-not (Test-Path -Path $summaryPath -PathType Leaf)) {
            throw "Missing validation summary: $summaryPath"
        }
        $summary = Get-Content -Path $summaryPath -Raw | ConvertFrom-Json

        $result = [pscustomobject]@{
            candidate_id = $candidateId
            dimension = [string]$dimension.name
            option_id = [string]$option.option_id
            set_file = $setPath
            validation_label = $validateLabel
            oos_median_pf = [double]$summary.oos_aggregate.median_pf
            oos_min_pf = [double]$summary.oos_aggregate.min_pf
            oos_max_dd_pct = [double]$summary.oos_aggregate.max_dd_pct
            oos_aggregate_pf = [double]$summary.oos_aggregate.aggregate_pf
            oos_trades = [int]$summary.oos_aggregate.trades
            oos_net_profit = [double]$summary.oos_aggregate.net_profit
            classification = [string]$summary.classification
        }
        $candidateResults.Add($result)

        if (Is-BetterCandidate -Candidate $result -Best $bestDim) {
            $bestDim = $result
        }
    }

    if ($null -eq $bestDim) {
        throw "No candidate selected for dimension $($dimension.name)"
    }

    $chosenSteps.Add($bestDim)
    $bestSetMap = Read-SetFile -Path $bestDim.set_file
    $workingMap = Copy-Hashtable -Source $bestSetMap
    Write-Host ("Selected for {0}: {1} (median PF={2:N4}, max DD={3:N2}%)" -f $dimension.name, $bestDim.option_id, $bestDim.oos_median_pf, $bestDim.oos_max_dd_pct)
}

$v2SetPath = Join-Path $repoRoot "profiles\\pf2_window_0607_v2.set"
Write-SetFile -Map $workingMap -Path $v2SetPath

$finalValidationLabel = "pf2_window_0607_v2_validation"
$finalValidateParams = @{
    SetFile = $v2SetPath
    Symbol = $Symbol
    Timeframe = $Timeframe
    OutputLabel = $finalValidationLabel
}
if ($CloseRunningTerminal.IsPresent) {
    $finalValidateParams.CloseRunningTerminal = $true
}

& $validateScript @finalValidateParams

$finalSummaryPath = Join-Path $repoRoot ("outputs\\validation\\{0}\\validation_summary.json" -f $finalValidationLabel)
if (-not (Test-Path -Path $finalSummaryPath -PathType Leaf)) {
    throw "Missing final validation summary: $finalSummaryPath"
}
$finalSummary = Get-Content -Path $finalSummaryPath -Raw | ConvertFrom-Json
$confirmRow = $finalSummary.folds | Where-Object { $_.fold_name -eq "confirm_is" } | Select-Object -First 1

$v2MetaPath = Join-Path $repoRoot "profiles\\pf2_window_0607_v2.meta.json"
$v2Meta = [ordered]@{
    profile_id = "pf2_window_0607_v2"
    symbol = $Symbol
    timeframe = $Timeframe
    validated_period_from = "2025.08.01"
    validated_period_to = "2026.02.22"
    pf = if ($confirmRow) { [double]$confirmRow.pf } else { [double]::NaN }
    dd_pct = if ($confirmRow) { [double]$confirmRow.dd_pct } else { [double]::NaN }
    trades = if ($confirmRow) { [int]$confirmRow.trades } else { 0 }
    notes = @(
        "Selected by staged constrained fallback search over session/exit/volatility controls.",
        ("Final validation classification: {0}" -f [string]$finalSummary.classification),
        ("OOS median PF: {0:N4}" -f [double]$finalSummary.oos_aggregate.median_pf),
        ("OOS max DD%: {0:N2}" -f [double]$finalSummary.oos_aggregate.max_dd_pct)
    )
    created_utc = (Get-Date).ToUniversalTime().ToString("o")
}
$v2Meta | ConvertTo-Json -Depth 5 | Set-Content -Path $v2MetaPath -Encoding ASCII

$scoresCsvPath = Join-Path $researchRoot "candidate_scores.csv"
$scoresJsonPath = Join-Path $researchRoot "candidate_scores.json"
$chosenJsonPath = Join-Path $researchRoot "chosen_steps.json"

$candidateResults | Export-Csv -Path $scoresCsvPath -NoTypeInformation -Encoding ASCII
$candidateResults | ConvertTo-Json -Depth 6 | Set-Content -Path $scoresJsonPath -Encoding ASCII
$chosenSteps | ConvertTo-Json -Depth 6 | Set-Content -Path $chosenJsonPath -Encoding ASCII

Write-Host ""
Write-Host "Fallback re-search complete."
Write-Host " V2 set          : $v2SetPath"
Write-Host " V2 metadata     : $v2MetaPath"
Write-Host " Final validation: outputs\\validation\\$finalValidationLabel\\validation_summary.json"
Write-Host " Candidate scores: $scoresCsvPath"
