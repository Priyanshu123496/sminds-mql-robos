[CmdletBinding()]
param(
    [string]$BaseSetFile = "profiles/xauusd_h1_ema_v1.set",
    [string]$Symbol = "XAUUSD",
    [string]$Timeframe = "H1",
    [string]$Expert = "XAUUSD_H1_EMACrossReversal.ex5",
    [string]$ExpertLogPrefix = "XAUUSD_H1_EMACrossReversal",
    [string]$OutputLabel = "xauusd_h1_ema_research",
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
        if ([string]::IsNullOrWhiteSpace($line)) { continue }
        if ($line.StartsWith(";")) { continue }
        $parts = $line.Split("=", 2)
        if ($parts.Count -ne 2) { continue }
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
        "RiskPerTradePct",
        "EmaFast",
        "EmaSlow",
        "UseBarCloseConfirmation",
        "FixedSLPoints",
        "UseFixedTP",
        "FixedTPPoints",
        "UseAtrTrail",
        "AtrPeriod",
        "TrailAtrMult",
        "UseBreakEven",
        "BreakEvenR",
        "UseAdxFilter",
        "AdxPeriod",
        "AdxMin",
        "UseVolatilityFilter",
        "MaxAtrToPricePct",
        "UseSessionFilter",
        "SessionStartServerHour",
        "SessionEndServerHour",
        "UseNewsFilter",
        "NewsBlockBeforeMin",
        "NewsBlockAfterMin",
        "NewsCurrencies",
        "MaxSpreadPoints",
        "FridayFlatHour",
        "FridayFlatMinute",
        "CommissionPerLotRT",
        "MinTradesForScore",
        "InterpretFixedSLAsPips",
        "PipSizePoints",
        "MaxMarginUsePct",
        "MaxVolumeLots",
        "RetryOnNoMoney",
        "MaxEntryRetries",
        "ManageStopsOnNewBarOnly",
        "MinStopUpdatePoints",
        "MinSecondsBetweenStopUpdates",
        "MaxEntryFailRatePct",
        "UseTrendRegimeFilter",
        "RegimeEmaPeriod",
        "RequireRegimeSlope",
        "RegimeSlopeBars",
        "MinRegimeSlopeAtr",
        "UseAtrStop",
        "AtrStopMult",
        "UseAtrTarget",
        "AtrTargetMult",
        "UseCooldownAfterLoss",
        "CooldownBarsAfterLoss",
        "UsePartialExit",
        "PartialExitR",
        "PartialExitPct"
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

function Get-TradeLogMetrics {
    param([Parameter(Mandatory = $true)][string]$TradeLogPath)

    $styles = [System.Globalization.NumberStyles]::Float
    $culture = [System.Globalization.CultureInfo]::InvariantCulture
    $profitRegex = [regex]"profit=([-+]?\d+(?:\.\d+)?)"

    $grossProfit = 0.0
    $grossLossAbs = 0.0
    $netProfit = 0.0
    $trades = 0
    $wins = 0
    $losses = 0
    $maxDrawdownPct = 0.0
    $peakBalance = [double]::NaN

    $rows = Import-Csv -Path $TradeLogPath -Delimiter ';'
    foreach ($row in $rows) {
        $balance = 0.0
        $balanceText = [string]$row.balance
        if ([double]::TryParse($balanceText, $styles, $culture, [ref]$balance)) {
            if ([double]::IsNaN($peakBalance) -or $balance -gt $peakBalance) {
                $peakBalance = $balance
            }
            if ($peakBalance -gt 0.0) {
                $drawdownPct = (($peakBalance - $balance) / $peakBalance) * 100.0
                if ($drawdownPct -gt $maxDrawdownPct) {
                    $maxDrawdownPct = $drawdownPct
                }
            }
        }

        if ([string]$row.event -ne "DEAL_OUT") { continue }

        $reasonText = [string]$row.reason
        $match = $profitRegex.Match($reasonText)
        if (-not $match.Success) { continue }

        $profit = [double]$match.Groups[1].Value
        $trades++
        $netProfit += $profit
        if ($profit -gt 0.0) {
            $grossProfit += $profit
            $wins++
        } elseif ($profit -lt 0.0) {
            $grossLossAbs += [Math]::Abs($profit)
            $losses++
        }
    }

    $pf = 0.0
    if ($grossLossAbs -gt 0.0) {
        $pf = $grossProfit / $grossLossAbs
    } elseif ($grossProfit -gt 0.0) {
        $pf = [double]::PositiveInfinity
    }

    $winRate = 0.0
    if ($trades -gt 0) {
        $winRate = 100.0 * $wins / $trades
    }

    return [ordered]@{
        pf = $pf
        dd_pct = $maxDrawdownPct
        trades = $trades
        wins = $wins
        losses = $losses
        win_rate_pct = $winRate
        net_profit = $netProfit
        gross_profit = $grossProfit
        gross_loss_abs = $grossLossAbs
    }
}

function Get-RunMetricsFromMetadata {
    param([Parameter(Mandatory = $true)][string]$MetadataPath)
    if (-not (Test-Path -Path $MetadataPath -PathType Leaf)) {
        return $null
    }
    $metadata = Get-Content -Path $MetadataPath -Raw | ConvertFrom-Json
    $tradeLog = [string]$metadata.trade_log_csv
    if ([string]::IsNullOrWhiteSpace($tradeLog) -or -not (Test-Path -Path $tradeLog -PathType Leaf)) {
        return $null
    }
    $metrics = Get-TradeLogMetrics -TradeLogPath $tradeLog
    $metrics["trade_log_csv"] = $tradeLog
    $metrics["report_xml"] = [string]$metadata.report_xml
    $metrics["report_html"] = [string]$metadata.report_html
    return $metrics
}

function To-ComparableMetric {
    param([double]$Value, [double]$DefaultIfNan)
    if ([double]::IsNaN($Value)) { return $DefaultIfNan }
    return $Value
}

function Value-OrDefault {
    param(
        [object]$Value,
        [object]$DefaultValue
    )
    if ($null -eq $Value) {
        return $DefaultValue
    }
    return $Value
}

function Is-BetterCandidate {
    param(
        [Parameter(Mandatory = $true)]$Candidate,
        [Parameter(Mandatory = $false)]$Best
    )
    if ($null -eq $Best) { return $true }

    $candMinPf = To-ComparableMetric -Value ([double]$Candidate.oos_min_pf) -DefaultIfNan -1.0e9
    $bestMinPf = To-ComparableMetric -Value ([double]$Best.oos_min_pf) -DefaultIfNan -1.0e9
    if ($candMinPf -gt $bestMinPf + 1.0e-9) { return $true }
    if ([Math]::Abs($candMinPf - $bestMinPf) -gt 1.0e-9) { return $false }

    $candMedian = To-ComparableMetric -Value ([double]$Candidate.oos_median_pf) -DefaultIfNan -1.0e9
    $bestMedian = To-ComparableMetric -Value ([double]$Best.oos_median_pf) -DefaultIfNan -1.0e9
    if ($candMedian -gt $bestMedian + 1.0e-9) { return $true }
    if ([Math]::Abs($candMedian - $bestMedian) -gt 1.0e-9) { return $false }

    $candDd = To-ComparableMetric -Value ([double]$Candidate.oos_max_dd_pct) -DefaultIfNan 1.0e9
    $bestDd = To-ComparableMetric -Value ([double]$Best.oos_max_dd_pct) -DefaultIfNan 1.0e9
    if ($candDd + 1.0e-9 -lt $bestDd) { return $true }
    if ([Math]::Abs($candDd - $bestDd) -gt 1.0e-9) { return $false }

    return ([int]$Candidate.oos_trades -gt [int]$Best.oos_trades)
}

$repoRoot = Resolve-AbsolutePath -PathValue (Join-Path $PSScriptRoot "..")
$runScript = Resolve-AbsolutePath -PathValue (Join-Path $PSScriptRoot "run_mt5_backtest.ps1")
$validateScript = Resolve-AbsolutePath -PathValue (Join-Path $PSScriptRoot "validate_profile.ps1")
$baseSetAbs = Resolve-AbsolutePath -PathValue $BaseSetFile

$researchRoot = Join-Path $repoRoot ("outputs\\research\\" + $OutputLabel)
$candidateSetDir = Join-Path $researchRoot "sets"
$null = New-Item -Path $candidateSetDir -ItemType Directory -Force

Write-Host "Running IS baseline (2020-01-01 to 2025-12-31)..."
$isOutputRel = Join-Path ("outputs\\research\\" + $OutputLabel) "is_baseline"
$isRunParams = @{
    SetFile = $baseSetAbs
    Symbol = $Symbol
    Timeframe = $Timeframe
    Expert = $Expert
    ExpertLogPrefix = $ExpertLogPrefix
    FromDate = "2020.01.01"
    ToDate = "2025.12.31"
    OutputRoot = $isOutputRel
    RunLabel = "is_baseline"
    SplitTag = "is_baseline"
}
if ($CloseRunningTerminal.IsPresent) { $isRunParams.CloseRunningTerminal = $true }
& $runScript @isRunParams

$isMetadataPath = Join-Path $repoRoot (Join-Path $isOutputRel "is_baseline\\run_metadata.json")
$isMetrics = Get-RunMetricsFromMetadata -MetadataPath $isMetadataPath

Write-Host "Validating v1 profile..."
$v1ValidationLabel = "xauusd_h1_ema_v1_validation"
$v1ValidateParams = @{
    SetFile = $baseSetAbs
    Symbol = $Symbol
    Timeframe = $Timeframe
    Expert = $Expert
    ExpertLogPrefix = $ExpertLogPrefix
    OutputLabel = $v1ValidationLabel
    ConfirmDdMax = 20.0
    ConfirmTradesMin = 30
    OosMinFoldsTrades = 3
    OosTradesPerFoldMin = 20
    OosMedianPfMin = 1.25
    OosMinPfMin = 0.95
    OosMaxDdMax = 25.0
    OosAggregatePfMin = 1.15
}
if ($CloseRunningTerminal.IsPresent) { $v1ValidateParams.CloseRunningTerminal = $true }
& $validateScript @v1ValidateParams

$v1SummaryPath = Join-Path $repoRoot ("outputs\\validation\\{0}\\validation_summary.json" -f $v1ValidationLabel)
$v1Summary = Get-Content -Path $v1SummaryPath -Raw | ConvertFrom-Json
$v1Confirm = $v1Summary.folds | Where-Object { $_.fold_name -eq "confirm_is" } | Select-Object -First 1

$v1Pf = if ($v1Confirm) { [double]$v1Confirm.pf } else { [double]::NaN }
$v1DdPct = if ($v1Confirm) { [double]$v1Confirm.dd_pct } else { [double]::NaN }
$v1Trades = if ($v1Confirm) { [int]$v1Confirm.trades } else { 0 }
$isPf = if ($isMetrics) { [string]([double]$isMetrics.pf) } else { "NaN" }
$isDdPct = if ($isMetrics) { [string]([double]$isMetrics.dd_pct) } else { "NaN" }
$isTrades = if ($isMetrics) { [string]([int]$isMetrics.trades) } else { "0" }

$v1MetaPath = Join-Path $repoRoot "profiles\\xauusd_h1_ema_v1.meta.json"
$v1Meta = [ordered]@{
    profile_id = "xauusd_h1_ema_v1"
    symbol = $Symbol
    timeframe = $Timeframe
    validated_period_from = "2025.08.01"
    validated_period_to = "2026.02.22"
    pf = $v1Pf
    dd_pct = $v1DdPct
    trades = $v1Trades
    notes = @(
        ("classification={0}" -f [string]$v1Summary.classification),
        ("is_2020_2025_pf={0}" -f $isPf),
        ("is_2020_2025_dd_pct={0}" -f $isDdPct),
        ("is_2020_2025_trades={0}" -f $isTrades)
    )
    created_utc = (Get-Date).ToUniversalTime().ToString("o")
}
$v1Meta | ConvertTo-Json -Depth 5 | Set-Content -Path $v1MetaPath -Encoding ASCII

$runFallbackSearch = ($v1Summary.classification -ne "production-candidate")
$candidateResults = New-Object System.Collections.Generic.List[object]
$chosenSteps = New-Object System.Collections.Generic.List[object]
$v2SetPath = Join-Path $repoRoot "profiles\\xauusd_h1_ema_v2.set"
$v2MetaPath = Join-Path $repoRoot "profiles\\xauusd_h1_ema_v2.meta.json"
$v2SummaryPath = $null
$holdoutMetrics = $null

if ($runFallbackSearch) {
    Write-Host "Running staged fallback re-search..."
    $workingMap = Read-SetFile -Path $baseSetAbs
    $searchAborted = $false
    $searchAbortReason = ""

    $stagePlan = @(
        [ordered]@{
            name = "RiskPct"
            options = @(
                [ordered]@{ option_id = "r02"; RiskPerTradePct = "0.2" },
                [ordered]@{ option_id = "r03"; RiskPerTradePct = "0.3" },
                [ordered]@{ option_id = "r04"; RiskPerTradePct = "0.4" }
            )
        },
        [ordered]@{
            name = "StopTarget"
            options = @(
                [ordered]@{ option_id = "st450_28"; FixedSLPoints = "45"; UseAtrStop = "true"; AtrStopMult = "2.0"; UseAtrTarget = "true"; AtrTargetMult = "2.8"; UseBreakEven = "true"; BreakEvenR = "0.9"; UseAtrTrail = "true"; TrailAtrMult = "1.4" },
                [ordered]@{ option_id = "st500_32"; FixedSLPoints = "50"; UseAtrStop = "true"; AtrStopMult = "2.2"; UseAtrTarget = "true"; AtrTargetMult = "3.2"; UseBreakEven = "true"; BreakEvenR = "1.0"; UseAtrTrail = "true"; TrailAtrMult = "1.5" },
                [ordered]@{ option_id = "st600_36"; FixedSLPoints = "60"; UseAtrStop = "true"; AtrStopMult = "2.4"; UseAtrTarget = "true"; AtrTargetMult = "3.6"; UseBreakEven = "true"; BreakEvenR = "1.1"; UseAtrTrail = "true"; TrailAtrMult = "1.6" },
                [ordered]@{ option_id = "st500_notgt"; FixedSLPoints = "50"; UseAtrStop = "true"; AtrStopMult = "2.2"; UseAtrTarget = "false"; UseBreakEven = "true"; BreakEvenR = "0.8"; UseAtrTrail = "true"; TrailAtrMult = "1.3" }
            )
        },
        [ordered]@{
            name = "Cooldown"
            options = @(
                [ordered]@{ option_id = "cd_off"; UseCooldownAfterLoss = "false"; CooldownBarsAfterLoss = "0" },
                [ordered]@{ option_id = "cd2"; UseCooldownAfterLoss = "true"; CooldownBarsAfterLoss = "2" },
                [ordered]@{ option_id = "cd3"; UseCooldownAfterLoss = "true"; CooldownBarsAfterLoss = "3" },
                [ordered]@{ option_id = "cd5"; UseCooldownAfterLoss = "true"; CooldownBarsAfterLoss = "5" }
            )
        },
        [ordered]@{
            name = "Partial"
            options = @(
                [ordered]@{ option_id = "px_off"; UsePartialExit = "false" },
                [ordered]@{ option_id = "px10_40"; UsePartialExit = "true"; PartialExitR = "1.0"; PartialExitPct = "40.0" },
                [ordered]@{ option_id = "px12_50"; UsePartialExit = "true"; PartialExitR = "1.2"; PartialExitPct = "50.0" },
                [ordered]@{ option_id = "px15_50"; UsePartialExit = "true"; PartialExitR = "1.5"; PartialExitPct = "50.0" }
            )
        },
        [ordered]@{
            name = "Regime"
            options = @(
                [ordered]@{ option_id = "rg_off"; UseTrendRegimeFilter = "false" },
                [ordered]@{ option_id = "rg200_s05"; UseTrendRegimeFilter = "true"; RegimeEmaPeriod = "200"; RequireRegimeSlope = "true"; RegimeSlopeBars = "3"; MinRegimeSlopeAtr = "0.05" },
                [ordered]@{ option_id = "rg200_s08"; UseTrendRegimeFilter = "true"; RegimeEmaPeriod = "200"; RequireRegimeSlope = "true"; RegimeSlopeBars = "4"; MinRegimeSlopeAtr = "0.08" },
                [ordered]@{ option_id = "rg150_s06"; UseTrendRegimeFilter = "true"; RegimeEmaPeriod = "150"; RequireRegimeSlope = "true"; RegimeSlopeBars = "3"; MinRegimeSlopeAtr = "0.06" }
            )
        },
        [ordered]@{
            name = "Session"
            options = @(
                [ordered]@{ option_id = "s0024"; UseSessionFilter = "true"; SessionStartServerHour = "0"; SessionEndServerHour = "24" },
                [ordered]@{ option_id = "s0618"; UseSessionFilter = "true"; SessionStartServerHour = "6"; SessionEndServerHour = "18" },
                [ordered]@{ option_id = "s0820"; UseSessionFilter = "true"; SessionStartServerHour = "8"; SessionEndServerHour = "20" },
                [ordered]@{ option_id = "s1222"; UseSessionFilter = "true"; SessionStartServerHour = "12"; SessionEndServerHour = "22" }
            )
        },
        [ordered]@{
            name = "AdxVol"
            options = @(
                [ordered]@{ option_id = "flt_off"; UseAdxFilter = "false"; UseVolatilityFilter = "false"; MaxAtrToPricePct = "0.80" },
                [ordered]@{ option_id = "adx18_vol080"; UseAdxFilter = "true"; AdxMin = "18.0"; UseVolatilityFilter = "true"; MaxAtrToPricePct = "0.80" },
                [ordered]@{ option_id = "adx20_vol060"; UseAdxFilter = "true"; AdxMin = "20.0"; UseVolatilityFilter = "true"; MaxAtrToPricePct = "0.60" },
                [ordered]@{ option_id = "adx22_vol050"; UseAdxFilter = "true"; AdxMin = "22.0"; UseVolatilityFilter = "true"; MaxAtrToPricePct = "0.50" }
            )
        },
        [ordered]@{
            name = "News"
            options = @(
                [ordered]@{ option_id = "noff"; UseNewsFilter = "false" },
                [ordered]@{ option_id = "non"; UseNewsFilter = "true" }
            )
        },
        [ordered]@{
            name = "Ema"
            options = @(
                [ordered]@{ option_id = "f18s45"; EmaFast = "18"; EmaSlow = "45" },
                [ordered]@{ option_id = "f20s50"; EmaFast = "20"; EmaSlow = "50" },
                [ordered]@{ option_id = "f22s55"; EmaFast = "22"; EmaSlow = "55" },
                [ordered]@{ option_id = "f22s60"; EmaFast = "22"; EmaSlow = "60" },
                [ordered]@{ option_id = "f24s70"; EmaFast = "24"; EmaSlow = "70" }
            )
        }
    )

    $candidateIndex = 0
    foreach ($stage in $stagePlan) {
        Write-Host ("Evaluating stage {0}..." -f [string]$stage.name)
        $bestStageCandidate = $null
        $stageCandidates = New-Object System.Collections.Generic.List[object]

        foreach ($option in $stage.options) {
            $candidateIndex++
            $candidateId = ("c{0:D3}_{1}_{2}" -f $candidateIndex, ([string]$stage.name).ToLower(), [string]$option.option_id)
            $candidateMap = Copy-Hashtable -Source $workingMap
            foreach ($key in $option.Keys) {
                if ($key -eq "option_id") { continue }
                $candidateMap[$key] = [string]$option[$key]
            }

            $setPath = Join-Path $candidateSetDir ($candidateId + ".set")
            Write-SetFile -Map $candidateMap -Path $setPath

            $label = ("{0}_{1}" -f $OutputLabel, $candidateId)
            $validateParams = @{
                SetFile = $setPath
                Symbol = $Symbol
                Timeframe = $Timeframe
                Expert = $Expert
                ExpertLogPrefix = $ExpertLogPrefix
                OutputLabel = $label
                ConfirmTradesMin = 4
                OosMinFoldsTrades = 3
                OosTradesPerFoldMin = 2
                OosMedianPfMin = 1.25
                OosMinPfMin = 0.95
                OosMaxDdMax = 25.0
                OosAggregatePfMin = 1.15
            }
            if ($CloseRunningTerminal.IsPresent) { $validateParams.CloseRunningTerminal = $true }
            & $validateScript @validateParams

            $summaryPath = Join-Path $repoRoot ("outputs\\validation\\{0}\\validation_summary.json" -f $label)
            $summary = Get-Content -Path $summaryPath -Raw | ConvertFrom-Json
            $confirm = $summary.folds | Where-Object { $_.fold_name -eq "confirm_is" } | Select-Object -First 1

            $holdoutOutputRel = Join-Path ("outputs\\research\\" + $OutputLabel) ("holdout_candidates\\" + $candidateId)
            $holdoutParams = @{
                SetFile = $setPath
                Symbol = $Symbol
                Timeframe = $Timeframe
                Expert = $Expert
                ExpertLogPrefix = $ExpertLogPrefix
                FromDate = "2026.01.01"
                ToDate = "2026.02.22"
                OutputRoot = $holdoutOutputRel
                RunLabel = $candidateId
                SplitTag = ("holdout_" + $candidateId)
            }
            if ($CloseRunningTerminal.IsPresent) { $holdoutParams.CloseRunningTerminal = $true }
            & $runScript @holdoutParams

            $holdoutMetadataPath = Join-Path $repoRoot (Join-Path $holdoutOutputRel ($candidateId + "\\run_metadata.json"))
            $candidateHoldoutMetrics = Get-RunMetricsFromMetadata -MetadataPath $holdoutMetadataPath
            $holdoutTrades = if ($candidateHoldoutMetrics) { [int]$candidateHoldoutMetrics.trades } else { 0 }
            $holdoutPf = if ($candidateHoldoutMetrics) { [double]$candidateHoldoutMetrics.pf } else { [double]::NaN }
            $holdoutDdPct = if ($candidateHoldoutMetrics) { [double]$candidateHoldoutMetrics.dd_pct } else { [double]::NaN }

            $confirmStatus = if ($confirm) { [string]$confirm.status } else { "missing" }
            $confirmTrades = if ($confirm) { [int]$confirm.trades } else { 0 }
            $confirmPf = if ($confirm) { [double]$confirm.pf } else { [double]::NaN }
            $confirmDdPct = if ($confirm) { [double]$confirm.dd_pct } else { [double]::NaN }
            $oosFoldsTrades20 = [int]$summary.oos_aggregate.folds_with_trades_min
            $entryFailRate = [double]$summary.execution_quality.entry_fail_rate_pct
            $noMoneyFailRate = [double]$summary.execution_quality.no_money_fail_rate_pct
            $enforceHoldoutTrades = ([string]$stage.name -eq "Ema")

            $prefilterReasons = New-Object System.Collections.Generic.List[string]
            if (-not $confirm -or $confirmStatus -ne "ok") { $null = $prefilterReasons.Add("confirm_status_not_ok") }
            if ($confirmTrades -lt 4) { $null = $prefilterReasons.Add("confirm_trades_lt4") }
            if ([double]::IsNaN($confirmPf) -or $confirmPf -lt 0.90) { $null = $prefilterReasons.Add("confirm_pf_lt0_90") }
            if ([double]::IsNaN($confirmDdPct) -or $confirmDdPct -gt 20.0) { $null = $prefilterReasons.Add("confirm_dd_gt20") }
            if ($enforceHoldoutTrades -and $holdoutTrades -lt 1) { $null = $prefilterReasons.Add("holdout_trades_lt1") }
            if ($oosFoldsTrades20 -lt 3) { $null = $prefilterReasons.Add("oos_folds_lt3_with_trades2") }
            if (-not [double]::IsNaN($noMoneyFailRate) -and $noMoneyFailRate -gt 2.0) { $null = $prefilterReasons.Add("no_money_fail_rate_gt2pct") }
            if (-not [double]::IsNaN($entryFailRate) -and $entryFailRate -gt 20.0) { $null = $prefilterReasons.Add("entry_fail_rate_gt20pct") }
            $prefilterPass = ($prefilterReasons.Count -eq 0)
            $prefilterReasonText = if ($prefilterPass) { "" } else { ($prefilterReasons -join ",") }

            $candidate = [pscustomobject]@{
                candidate_id = $candidateId
                stage = [string]$stage.name
                option_id = [string]$option.option_id
                set_file = $setPath
                validation_label = $label
                confirm_status = $confirmStatus
                confirm_pf = $confirmPf
                confirm_dd_pct = $confirmDdPct
                confirm_trades = $confirmTrades
                holdout_trades = $holdoutTrades
                holdout_pf = $holdoutPf
                holdout_dd_pct = $holdoutDdPct
                oos_folds_trades20 = $oosFoldsTrades20
                entry_fail_rate_pct = $entryFailRate
                no_money_fail_rate_pct = $noMoneyFailRate
                oos_median_pf = [double]$summary.oos_aggregate.median_pf
                oos_min_pf = [double]$summary.oos_aggregate.min_pf
                oos_max_dd_pct = [double]$summary.oos_aggregate.max_dd_pct
                oos_aggregate_pf = [double]$summary.oos_aggregate.aggregate_pf
                oos_trades = [int]$summary.oos_aggregate.trades
                oos_net_profit = [double]$summary.oos_aggregate.net_profit
                prefilter_pass = $prefilterPass
                prefilter_fail_reason = $prefilterReasonText
            }
            $stageCandidates.Add($candidate)
            $candidateResults.Add($candidate)
        }

        $eligible = @($stageCandidates | Where-Object { $_.prefilter_pass -eq $true })
        if ($eligible.Count -le 0) {
            $searchAborted = $true
            $searchAbortReason = "No prefilter-passing candidate in stage $($stage.name)."
            Write-Warning $searchAbortReason
            break
        }

        foreach ($candidate in $eligible) {
            if (Is-BetterCandidate -Candidate $candidate -Best $bestStageCandidate) {
                $bestStageCandidate = $candidate
            }
        }

        if ($null -eq $bestStageCandidate) {
            throw "No stage winner selected for $($stage.name)."
        }

        $chosenSteps.Add($bestStageCandidate)
        $workingMap = Read-SetFile -Path $bestStageCandidate.set_file
        Write-Host ("Stage {0} winner: {1} (min PF={2:N4}, median PF={3:N4}, max DD={4:N2}%)" -f $stage.name, $bestStageCandidate.option_id, $bestStageCandidate.oos_min_pf, $bestStageCandidate.oos_median_pf, $bestStageCandidate.oos_max_dd_pct)
    }

    if (-not $searchAborted) {
        Write-SetFile -Map $workingMap -Path $v2SetPath

        $v2ValidationLabel = "xauusd_h1_ema_v2_validation"
        $v2ValidateParams = @{
            SetFile = $v2SetPath
            Symbol = $Symbol
            Timeframe = $Timeframe
            Expert = $Expert
            ExpertLogPrefix = $ExpertLogPrefix
            OutputLabel = $v2ValidationLabel
            ConfirmDdMax = 20.0
            ConfirmTradesMin = 30
            OosMinFoldsTrades = 3
            OosTradesPerFoldMin = 20
            OosMedianPfMin = 1.25
            OosMinPfMin = 0.95
            OosMaxDdMax = 25.0
            OosAggregatePfMin = 1.15
        }
        if ($CloseRunningTerminal.IsPresent) { $v2ValidateParams.CloseRunningTerminal = $true }
        & $validateScript @v2ValidateParams

        $v2SummaryPath = Join-Path $repoRoot ("outputs\\validation\\{0}\\validation_summary.json" -f $v2ValidationLabel)
        $v2Summary = Get-Content -Path $v2SummaryPath -Raw | ConvertFrom-Json
        $v2Confirm = $v2Summary.folds | Where-Object { $_.fold_name -eq "confirm_is" } | Select-Object -First 1

        Write-Host "Running holdout test for v2 (2026-01-01 to 2026-02-22)..."
        $holdoutOutputRel = Join-Path ("outputs\\research\\" + $OutputLabel) "holdout_v2"
        $holdoutParams = @{
            SetFile = $v2SetPath
            Symbol = $Symbol
            Timeframe = $Timeframe
            Expert = $Expert
            ExpertLogPrefix = $ExpertLogPrefix
            FromDate = "2026.01.01"
            ToDate = "2026.02.22"
            OutputRoot = $holdoutOutputRel
            RunLabel = "holdout_v2"
            SplitTag = "holdout_v2"
        }
        if ($CloseRunningTerminal.IsPresent) { $holdoutParams.CloseRunningTerminal = $true }
        & $runScript @holdoutParams

        $holdoutMetadataPath = Join-Path $repoRoot (Join-Path $holdoutOutputRel "holdout_v2\\run_metadata.json")
        $holdoutMetrics = Get-RunMetricsFromMetadata -MetadataPath $holdoutMetadataPath

        $v2Pf = if ($v2Confirm) { [double]$v2Confirm.pf } else { [double]::NaN }
        $v2DdPct = if ($v2Confirm) { [double]$v2Confirm.dd_pct } else { [double]::NaN }
        $v2Trades = if ($v2Confirm) { [int]$v2Confirm.trades } else { 0 }
        $holdoutPf = if ($holdoutMetrics) { [string]([double]$holdoutMetrics.pf) } else { "NaN" }
        $holdoutDdPct = if ($holdoutMetrics) { [string]([double]$holdoutMetrics.dd_pct) } else { "NaN" }
        $holdoutTrades = if ($holdoutMetrics) { [string]([int]$holdoutMetrics.trades) } else { "0" }

        $v2Meta = [ordered]@{
            profile_id = "xauusd_h1_ema_v2"
            symbol = $Symbol
            timeframe = $Timeframe
            validated_period_from = "2025.08.01"
            validated_period_to = "2026.02.22"
            pf = $v2Pf
            dd_pct = $v2DdPct
            trades = $v2Trades
            notes = @(
                ("classification={0}" -f [string]$v2Summary.classification),
                ("oos_median_pf={0:N4}" -f [double]$v2Summary.oos_aggregate.median_pf),
                ("oos_max_dd_pct={0:N2}" -f [double]$v2Summary.oos_aggregate.max_dd_pct),
                ("holdout_pf={0}" -f $holdoutPf),
                ("holdout_dd_pct={0}" -f $holdoutDdPct),
                ("holdout_trades={0}" -f $holdoutTrades)
            )
            created_utc = (Get-Date).ToUniversalTime().ToString("o")
        }
        $v2Meta | ConvertTo-Json -Depth 5 | Set-Content -Path $v2MetaPath -Encoding ASCII
    } else {
        Write-Warning ("Fallback search stopped early: {0}" -f $searchAbortReason)
    }
}

$candidateScoresCsv = Join-Path $researchRoot "candidate_scores.csv"
$candidateScoresJson = Join-Path $researchRoot "candidate_scores.json"
$chosenStepsJson = Join-Path $researchRoot "chosen_steps.json"

if ($candidateResults.Count -gt 0) {
    $candidateResults | Export-Csv -Path $candidateScoresCsv -NoTypeInformation -Encoding ASCII
    $candidateResults | ConvertTo-Json -Depth 6 | Set-Content -Path $candidateScoresJson -Encoding ASCII
} else {
    @() | Export-Csv -Path $candidateScoresCsv -NoTypeInformation -Encoding ASCII
    "[]" | Set-Content -Path $candidateScoresJson -Encoding ASCII
}

$chosenJson = "[]"
if ($chosenSteps.Count -gt 0) {
    $chosenJson = $chosenSteps | ConvertTo-Json -Depth 6
}
$chosenJson | Set-Content -Path $chosenStepsJson -Encoding ASCII

$v2SetOut = $null
$v2MetaOut = $null
if ($runFallbackSearch -and (Value-OrDefault -Value $searchAborted -DefaultValue $false) -eq $false) {
    if (Test-Path -Path $v2SetPath -PathType Leaf) { $v2SetOut = $v2SetPath }
    if (Test-Path -Path $v2MetaPath -PathType Leaf) { $v2MetaOut = $v2MetaPath }
}

$summary = [ordered]@{
    output_label = $OutputLabel
    symbol = $Symbol
    timeframe = $Timeframe
    expert = $Expert
    expert_log_prefix = $ExpertLogPrefix
    baseline_is_metrics = $isMetrics
    v1_validation_summary = $v1SummaryPath
    v1_meta = $v1MetaPath
    fallback_search_ran = $runFallbackSearch
    fallback_search_aborted = if ($runFallbackSearch) { Value-OrDefault -Value $searchAborted -DefaultValue $false } else { $false }
    fallback_search_abort_reason = if ($runFallbackSearch) { Value-OrDefault -Value $searchAbortReason -DefaultValue "" } else { "" }
    v2_set = $v2SetOut
    v2_meta = $v2MetaOut
    v2_validation_summary = $v2SummaryPath
    holdout_v2_metrics = $holdoutMetrics
    created_utc = (Get-Date).ToUniversalTime().ToString("o")
}

$summaryPath = Join-Path $researchRoot "research_summary.json"
$summary | ConvertTo-Json -Depth 8 | Set-Content -Path $summaryPath -Encoding ASCII

Write-Host ""
Write-Host "H1 EMA research complete."
Write-Host " Summary: $summaryPath"
Write-Host " v1 meta: $v1MetaPath"
if ($runFallbackSearch) {
    Write-Host " v2 set : $v2SetPath"
    Write-Host " v2 meta: $v2MetaPath"
}
