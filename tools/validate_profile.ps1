[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [string]$SetFile,
    [string]$Symbol = "XAUUSD",
    [string]$Timeframe = "M15",
    [string]$Expert = "XAUUSD_RobustBreakout.ex5",
    [string]$ExpertLogPrefix = "XAUUSD_RobustBreakout",
    [string]$OutputLabel = "",
    [switch]$CloseRunningTerminal,
    [switch]$SkipConfirmFolds,
    [double]$ConfirmPfMin = 2.0,
    [double]$ConfirmDdMax = 15.0,
    [int]$ConfirmTradesMin = 30,
    [int]$OosMinFoldsTrades = 3,
    [int]$OosTradesPerFoldMin = 20,
    [double]$OosMedianPfMin = 1.25,
    [double]$OosMinPfMin = 0.95,
    [double]$OosMaxDdMax = 25.0,
    [double]$OosAggregatePfMin = 1.15
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

function Resolve-AbsolutePath {
    param([Parameter(Mandatory = $true)][string]$PathValue)
    $resolved = Resolve-Path -Path $PathValue -ErrorAction Stop
    return $resolved.ProviderPath
}

function Get-PythonCommand {
    $python = Get-Command python -ErrorAction SilentlyContinue
    if ($python) {
        return $python.Source
    }
    $py = Get-Command py -ErrorAction SilentlyContinue
    if ($py) {
        return "$($py.Source) -3"
    }
    throw "Python executable not found (python/py)."
}

function To-InvariantDouble {
    param([string]$TextValue)
    $styles = [System.Globalization.NumberStyles]::Float
    $culture = [System.Globalization.CultureInfo]::InvariantCulture
    $result = 0.0
    if ([double]::TryParse($TextValue, $styles, $culture, [ref]$result)) {
        return $result
    }
    return [double]::NaN
}

function Get-Median {
    param([double[]]$Values)
    if (-not $Values -or $Values.Count -eq 0) {
        return [double]::NaN
    }
    $sorted = $Values | Sort-Object
    $n = $sorted.Count
    if (($n % 2) -eq 1) {
        return [double]$sorted[[int]($n / 2)]
    }
    $left = [double]$sorted[($n / 2) - 1]
    $right = [double]$sorted[$n / 2]
    return ($left + $right) / 2.0
}

function Sum-NumberProperty {
    param(
        [object[]]$Rows,
        [Parameter(Mandatory = $true)][string]$Property
    )

    $items = @($Rows)
    if (-not $items -or $items.Count -eq 0) {
        return 0.0
    }

    $measure = $items | Measure-Object -Property $Property -Sum
    if ($null -eq $measure -or $null -eq $measure.Sum) {
        return 0.0
    }

    return [double]$measure.Sum
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

        if ([string]$row.event -ne "DEAL_OUT") {
            continue
        }

        $reasonText = [string]$row.reason
        $match = $profitRegex.Match($reasonText)
        if (-not $match.Success) {
            continue
        }

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

    $profitFactor = 0.0
    if ($grossLossAbs -gt 0.0) {
        $profitFactor = $grossProfit / $grossLossAbs
    } elseif ($grossProfit -gt 0.0) {
        $profitFactor = [double]::PositiveInfinity
    }

    $winRatePct = 0.0
    if ($trades -gt 0) {
        $winRatePct = (100.0 * $wins) / $trades
    }

    return [ordered]@{
        pf = $profitFactor
        dd_pct = $maxDrawdownPct
        trades = $trades
        wins = $wins
        losses = $losses
        win_rate_pct = $winRatePct
        net_profit = $netProfit
        gross_profit = $grossProfit
        gross_loss_abs = $grossLossAbs
    }
}

function Get-ExecutionMetrics {
    param([Parameter(Mandatory = $true)][string]$TradeLogPath)

    $rows = Import-Csv -Path $TradeLogPath -Delimiter ';'

    $entryAttempts = 0
    $entrySuccess = 0
    $entryFailNoMoney = 0
    $entryFailOther = 0
    $stopModifyAttempts = 0
    $stopModifySuccess = 0

    foreach ($row in $rows) {
        $eventName = [string]$row.event
        $reason = [string]$row.reason

        if ($eventName -eq "ENTRY") {
            $entryAttempts++
            $entrySuccess++
            continue
        }

        if ($eventName -eq "ENTRY_FAIL") {
            $entryAttempts++
            if ($reason -eq "NoMoney") {
                $entryFailNoMoney++
            } else {
                $entryFailOther++
            }
            continue
        }

        if ($eventName -eq "SL_UPDATE") {
            $stopModifyAttempts++
            $stopModifySuccess++
            continue
        }

        if ($eventName -eq "SL_UPDATE_FAIL") {
            $stopModifyAttempts++
            continue
        }
    }

    $entryFailTotal = $entryAttempts - $entrySuccess
    $entryFailRatePct = [double]::NaN
    $noMoneyFailRatePct = [double]::NaN
    if ($entryAttempts -gt 0) {
        $entryFailRatePct = (100.0 * $entryFailTotal) / $entryAttempts
        $noMoneyFailRatePct = (100.0 * $entryFailNoMoney) / $entryAttempts
    }

    return [ordered]@{
        entry_attempts = $entryAttempts
        entry_success = $entrySuccess
        entry_fail_total = $entryFailTotal
        entry_fail_no_money = $entryFailNoMoney
        entry_fail_other = $entryFailOther
        stop_modify_attempts = $stopModifyAttempts
        stop_modify_success = $stopModifySuccess
        entry_fail_rate_pct = $entryFailRatePct
        no_money_fail_rate_pct = $noMoneyFailRatePct
    }
}

function Get-FallbackXmlMetrics {
    param([string]$ReportXmlPath)

    if ([string]::IsNullOrWhiteSpace($ReportXmlPath) -or -not (Test-Path -Path $ReportXmlPath -PathType Leaf)) {
        return $null
    }

    try {
        [xml]$doc = Get-Content -Path $ReportXmlPath -Raw
        $root = $doc.mt5_report
        if (-not $root) {
            return $null
        }

        $sourceAttr = [string]$root.source
        if ($sourceAttr -ne "trade_log_fallback") {
            return $null
        }

        $pfText = [string]$root.profit_factor
        $pfValue = if ($pfText -eq "INF") { [double]::PositiveInfinity } else { To-InvariantDouble -TextValue $pfText }

        return [ordered]@{
            pf = $pfValue
            dd_pct = To-InvariantDouble -TextValue ([string]$root.drawdown_pct)
            trades = [int]([string]$root.trades)
            net_profit = To-InvariantDouble -TextValue ([string]$root.net_profit)
            gross_profit = To-InvariantDouble -TextValue ([string]$root.gross_profit)
            gross_loss_abs = To-InvariantDouble -TextValue ([string]$root.gross_loss_abs)
        }
    } catch {
        return $null
    }
}

function Compare-Float {
    param(
        [double]$Left,
        [double]$Right,
        [double]$Tolerance
    )

    if ([double]::IsNaN($Left) -or [double]::IsNaN($Right)) {
        return $false
    }

    if ([double]::IsInfinity($Left) -and [double]::IsInfinity($Right)) {
        return $true
    }

    return ([Math]::Abs($Left - $Right) -le $Tolerance)
}

function Format-Scalar {
    param([object]$Value)
    if ($null -eq $Value) {
        return ""
    }
    if ($Value -is [double]) {
        $dv = [double]$Value
        if ([double]::IsNaN($dv)) {
            return "NaN"
        }
        if ([double]::IsInfinity($dv)) {
            return "INF"
        }
        return $dv.ToString("0.######", [System.Globalization.CultureInfo]::InvariantCulture)
    }
    return [string]$Value
}

if ([string]::IsNullOrWhiteSpace($OutputLabel)) {
    $OutputLabel = "validation_{0}" -f (Get-Date -Format "yyyyMMdd_HHmmss")
}

$repoRoot = Resolve-AbsolutePath -PathValue (Join-Path $PSScriptRoot "..")
$runScript = Resolve-AbsolutePath -PathValue (Join-Path $PSScriptRoot "run_mt5_backtest.ps1")
$analyzeScript = Resolve-AbsolutePath -PathValue (Join-Path $PSScriptRoot "analyze_trade_log.py")
$setFileAbs = Resolve-AbsolutePath -PathValue $SetFile
$pythonCmd = Get-PythonCommand

$validationRootRel = Join-Path "outputs\\validation" $OutputLabel
$validationRootAbs = Join-Path $repoRoot $validationRootRel
$null = New-Item -Path $validationRootAbs -ItemType Directory -Force

$matrix = @()
if (-not $SkipConfirmFolds.IsPresent) {
    $matrix += [ordered]@{ name = "confirm_is"; from = "2025.08.01"; to = "2026.02.22"; kind = "confirm" }
    $matrix += [ordered]@{ name = "confirm_is_repeat"; from = "2025.08.01"; to = "2026.02.22"; kind = "confirm_repeat" }
}
$matrix += [ordered]@{ name = "fold_01"; from = "2025.02.01"; to = "2025.07.31"; kind = "oos" }
$matrix += [ordered]@{ name = "fold_02"; from = "2024.08.01"; to = "2025.01.31"; kind = "oos" }
$matrix += [ordered]@{ name = "fold_03"; from = "2024.02.01"; to = "2024.07.31"; kind = "oos" }
$matrix += [ordered]@{ name = "fold_04"; from = "2023.08.01"; to = "2024.01.31"; kind = "oos" }
$matrix += [ordered]@{ name = "fold_05"; from = "2023.02.01"; to = "2023.07.31"; kind = "oos" }

$rows = New-Object System.Collections.Generic.List[object]

foreach ($fold in $matrix) {
    $foldName = [string]$fold.name
    $fromDate = [string]$fold.from
    $toDate = [string]$fold.to
    $foldKind = [string]$fold.kind
    $isOos = ($foldKind -eq "oos")

    Write-Host ("[{0}] Running fold {1} ({2} -> {3})" -f (Get-Date -Format "HH:mm:ss"), $foldName, $fromDate, $toDate)

    $foldRootRel = Join-Path $validationRootRel $foldName
    $runParams = @{
        SetFile = $setFileAbs
        Symbol = $Symbol
        Timeframe = $Timeframe
        Expert = $Expert
        ExpertLogPrefix = $ExpertLogPrefix
        FromDate = $fromDate
        ToDate = $toDate
        OutputRoot = $foldRootRel
        RunLabel = $foldName
        SplitTag = $foldName
    }
    if ($CloseRunningTerminal.IsPresent) {
        $runParams.CloseRunningTerminal = $true
    }

    & $runScript @runParams

    $runDir = Join-Path $repoRoot (Join-Path $foldRootRel $foldName)
    $metadataPath = Join-Path $runDir "run_metadata.json"

    $status = "ok"
    $notes = @()
    $pf = [double]::NaN
    $ddPct = [double]::NaN
    $trades = 0
    $netProfit = [double]::NaN
    $grossProfit = [double]::NaN
    $grossLossAbs = [double]::NaN
    $winRatePct = [double]::NaN
    $tradeLogPath = $null
    $reportXmlPath = $null
    $reportHtmlPath = $null
    $analysisJsonPath = $null
    $consistencyOk = $true
    $entryAttempts = 0
    $entrySuccess = 0
    $entryFailNoMoney = 0
    $entryFailOther = 0
    $entryFailRatePct = [double]::NaN
    $noMoneyFailRatePct = [double]::NaN

    if (-not (Test-Path -Path $metadataPath -PathType Leaf)) {
        $status = "insufficient_data"
        $notes += "missing_run_metadata"
    } else {
        $metadata = Get-Content -Path $metadataPath -Raw | ConvertFrom-Json
        $tradeLogPath = [string]$metadata.trade_log_csv
        $reportXmlPath = [string]$metadata.report_xml
        $reportHtmlPath = [string]$metadata.report_html

        if ([string]::IsNullOrWhiteSpace($tradeLogPath) -or -not (Test-Path -Path $tradeLogPath -PathType Leaf)) {
            $status = "insufficient_data"
            $notes += "missing_trade_log"
        } else {
            $analysisPrefix = Join-Path $runDir "analysis"
            & $pythonCmd $analyzeScript --log $tradeLogPath --output-prefix $analysisPrefix | Out-Host
            $analysisJsonPath = "$analysisPrefix.json"

            $metrics = Get-TradeLogMetrics -TradeLogPath $tradeLogPath
            $execution = Get-ExecutionMetrics -TradeLogPath $tradeLogPath
            $pf = [double]$metrics.pf
            $ddPct = [double]$metrics.dd_pct
            $trades = [int]$metrics.trades
            $netProfit = [double]$metrics.net_profit
            $grossProfit = [double]$metrics.gross_profit
            $grossLossAbs = [double]$metrics.gross_loss_abs
            $winRatePct = [double]$metrics.win_rate_pct
            $entryAttempts = [int]$execution.entry_attempts
            $entrySuccess = [int]$execution.entry_success
            $entryFailNoMoney = [int]$execution.entry_fail_no_money
            $entryFailOther = [int]$execution.entry_fail_other
            $entryFailRatePct = [double]$execution.entry_fail_rate_pct
            $noMoneyFailRatePct = [double]$execution.no_money_fail_rate_pct

            if ($trades -le 0) {
                if ($entryAttempts -gt 0 -and (($entryFailNoMoney + $entryFailOther) -gt 0)) {
                    $status = "execution_blocked"
                    $notes += "zero_trades_entry_failures"
                } else {
                    $status = "insufficient_data"
                    $notes += "zero_trades"
                }
            }

            if (Test-Path -Path $analysisJsonPath -PathType Leaf) {
                $analysis = Get-Content -Path $analysisJsonPath -Raw | ConvertFrom-Json
                $analysisTrades = [int]$analysis.trade_metrics.trades
                $analysisGrossProfit = [double]$analysis.trade_metrics.gross_profit
                $analysisGrossLoss = [double]$analysis.trade_metrics.gross_loss
                $analysisNetProfit = [double]$analysis.trade_metrics.net_profit
                $analysisWins = [int]$analysis.trade_metrics.wins
                $analysisWinRatePct = [double]$analysis.trade_metrics.win_rate_pct

                $analysisGrossLossAbs = [Math]::Abs($analysisGrossLoss)
                $analysisPf = if ($analysisGrossLossAbs -gt 0.0) { $analysisGrossProfit / $analysisGrossLossAbs } elseif ($analysisGrossProfit -gt 0.0) { [double]::PositiveInfinity } else { 0.0 }

                $consistencyChecks = @(
                    ($trades -eq $analysisTrades),
                    (Compare-Float -Left $pf -Right $analysisPf -Tolerance 0.02),
                    (Compare-Float -Left $netProfit -Right $analysisNetProfit -Tolerance 0.5),
                    (Compare-Float -Left $winRatePct -Right $analysisWinRatePct -Tolerance 0.1),
                    ($metrics.wins -eq $analysisWins)
                )
                if ($consistencyChecks -contains $false) {
                    $consistencyOk = $false
                    $notes += "analysis_mismatch"
                }
            } else {
                $consistencyOk = $false
                $notes += "missing_analysis_json"
            }

            $fallbackXmlMetrics = Get-FallbackXmlMetrics -ReportXmlPath $reportXmlPath
            if ($fallbackXmlMetrics) {
                $fallbackChecks = @(
                    ($trades -eq [int]$fallbackXmlMetrics.trades),
                    (Compare-Float -Left $pf -Right ([double]$fallbackXmlMetrics.pf) -Tolerance 0.02),
                    (Compare-Float -Left $ddPct -Right ([double]$fallbackXmlMetrics.dd_pct) -Tolerance 0.2),
                    (Compare-Float -Left $netProfit -Right ([double]$fallbackXmlMetrics.net_profit) -Tolerance 1.0),
                    (Compare-Float -Left $grossProfit -Right ([double]$fallbackXmlMetrics.gross_profit) -Tolerance 1.0),
                    (Compare-Float -Left $grossLossAbs -Right ([double]$fallbackXmlMetrics.gross_loss_abs) -Tolerance 1.0)
                )
                if ($fallbackChecks -contains $false) {
                    $consistencyOk = $false
                    $notes += "fallback_xml_mismatch"
                }
            }

            if (-not $consistencyOk -and $status -eq "ok") {
                $status = "inconsistent_metrics"
            }
        }
    }

    $rows.Add([pscustomobject]@{
            fold_name = $foldName
            kind = $foldKind
            is_oos = $isOos
            from_date = $fromDate
            to_date = $toDate
            status = $status
            pf = $pf
            dd_pct = $ddPct
            trades = $trades
            net_profit = $netProfit
            gross_profit = $grossProfit
            gross_loss_abs = $grossLossAbs
            win_rate_pct = $winRatePct
            consistency_ok = $consistencyOk
            entry_attempts = $entryAttempts
            entry_success = $entrySuccess
            entry_fail_no_money = $entryFailNoMoney
            entry_fail_other = $entryFailOther
            entry_fail_rate_pct = $entryFailRatePct
            no_money_fail_rate_pct = $noMoneyFailRatePct
            notes = ($notes -join ",")
            run_dir = $runDir
            report_xml = $reportXmlPath
            report_html = $reportHtmlPath
            trade_log_csv = $tradeLogPath
            analysis_json = $analysisJsonPath
        })
}

$confirm = $rows | Where-Object { $_.fold_name -eq "confirm_is" } | Select-Object -First 1
$confirmRepeat = $rows | Where-Object { $_.fold_name -eq "confirm_is_repeat" } | Select-Object -First 1
$oosRows = @($rows | Where-Object { $_.kind -eq "oos" })
$oosValid = @($oosRows | Where-Object { $_.status -ne "insufficient_data" -and $_.trades -gt 0 })

$oosPfValues = @($oosValid | ForEach-Object { [double]$_.pf })
$oosDdValues = @($oosValid | ForEach-Object { [double]$_.dd_pct })
$oosTrade20Count = @($oosRows | Where-Object { $_.trades -ge $OosTradesPerFoldMin }).Count

$oosMedianPf = Get-Median -Values $oosPfValues
$oosMinPf = if ($oosPfValues.Count -gt 0) { ($oosPfValues | Measure-Object -Minimum).Minimum } else { [double]::NaN }
$oosMaxDd = if ($oosDdValues.Count -gt 0) { ($oosDdValues | Measure-Object -Maximum).Maximum } else { [double]::NaN }

$oosGrossProfit = Sum-NumberProperty -Rows $oosValid -Property "gross_profit"
$oosGrossLossAbs = Sum-NumberProperty -Rows $oosValid -Property "gross_loss_abs"
$oosTrades = [int](Sum-NumberProperty -Rows $oosValid -Property "trades")
$oosNetProfit = Sum-NumberProperty -Rows $oosValid -Property "net_profit"
$oosWins = 0
foreach ($row in $oosValid) {
    if ($row.trades -gt 0 -and $row.win_rate_pct -ge 0) {
        $oosWins += [int][Math]::Round($row.trades * ($row.win_rate_pct / 100.0), 0)
    }
}
$oosWinRate = if ($oosTrades -gt 0) { (100.0 * $oosWins) / $oosTrades } else { [double]::NaN }
$oosAggregatePf = if ($oosGrossLossAbs -gt 0.0) { $oosGrossProfit / $oosGrossLossAbs } elseif ($oosGrossProfit -gt 0.0) { [double]::PositiveInfinity } else { [double]::NaN }

$determinismPfDelta = [double]::NaN
$determinismPass = $false
if ($confirm -and $confirmRepeat -and $confirm.status -eq "ok" -and $confirmRepeat.status -eq "ok" -and [int]$confirm.trades -gt 0 -and [int]$confirmRepeat.trades -gt 0) {
    $determinismPfDelta = [Math]::Abs([double]$confirm.pf - [double]$confirmRepeat.pf)
    $determinismPass = ($determinismPfDelta -le 0.02)
}

$gateConfirm = $false
if ($confirm -and $confirm.status -eq "ok") {
    $gateConfirm = ([double]$confirm.pf -ge $ConfirmPfMin -and [double]$confirm.dd_pct -le $ConfirmDdMax -and [int]$confirm.trades -ge $ConfirmTradesMin)
}
$gateMinTradeFolds = ($oosTrade20Count -ge $OosMinFoldsTrades)
$gateOosMedian = (-not [double]::IsNaN($oosMedianPf) -and $oosMedianPf -ge $OosMedianPfMin)
$gateOosMin = (-not [double]::IsNaN($oosMinPf) -and $oosMinPf -ge $OosMinPfMin)
$gateOosMaxDd = (-not [double]::IsNaN($oosMaxDd) -and $oosMaxDd -le $OosMaxDdMax)
$gateOosAggPf = (-not [double]::IsNaN($oosAggregatePf) -and $oosAggregatePf -ge $OosAggregatePfMin)

$isProductionCandidate = ($gateConfirm -and $gateMinTradeFolds -and $gateOosMedian -and $gateOosMin -and $gateOosMaxDd -and $gateOosAggPf)
$classification = if ($isProductionCandidate) { "production-candidate" } else { "niche-profile" }

$entryAttemptsTotal = [int](Sum-NumberProperty -Rows $rows -Property "entry_attempts")
$entrySuccessTotal = [int](Sum-NumberProperty -Rows $rows -Property "entry_success")
$entryFailNoMoneyTotal = [int](Sum-NumberProperty -Rows $rows -Property "entry_fail_no_money")
$entryFailOtherTotal = [int](Sum-NumberProperty -Rows $rows -Property "entry_fail_other")
$entryFailTotal = $entryFailNoMoneyTotal + $entryFailOtherTotal
$entryFailRatePct = [double]::NaN
$noMoneyFailRatePct = [double]::NaN
if ($entryAttemptsTotal -gt 0) {
    $entryFailRatePct = (100.0 * $entryFailTotal) / $entryAttemptsTotal
    $noMoneyFailRatePct = (100.0 * $entryFailNoMoneyTotal) / $entryAttemptsTotal
}

$summary = [ordered]@{
    profile_set = $setFileAbs
    symbol = $Symbol
    timeframe = $Timeframe
    expert = $Expert
    expert_log_prefix = $ExpertLogPrefix
    output_label = $OutputLabel
    created_utc = (Get-Date).ToUniversalTime().ToString("o")
    classification = $classification
    thresholds = [ordered]@{
        confirm_pf_min = $ConfirmPfMin
        confirm_dd_max = $ConfirmDdMax
        confirm_trades_min = $ConfirmTradesMin
        oos_min_folds_trades = $OosMinFoldsTrades
        oos_trades_per_fold_min = $OosTradesPerFoldMin
        oos_median_pf_min = $OosMedianPfMin
        oos_min_pf_min = $OosMinPfMin
        oos_max_dd_max = $OosMaxDdMax
        oos_aggregate_pf_min = $OosAggregatePfMin
    }
    gates = [ordered]@{
        confirm_is_pf_dd_trades = $gateConfirm
        min_oos_folds_with_trades_min = $gateMinTradeFolds
        oos_median_pf_ge_1_25 = $gateOosMedian
        oos_min_pf_ge_0_95 = $gateOosMin
        oos_max_dd_le_25 = $gateOosMaxDd
        oos_aggregate_pf_ge_1_15 = $gateOosAggPf
    }
    determinism_check = [ordered]@{
        confirm_is_repeat_present = [bool]($confirmRepeat -ne $null)
        pf_delta = $determinismPfDelta
        tolerance = 0.02
        pass = $determinismPass
    }
    oos_aggregate = [ordered]@{
        valid_folds = @($oosValid).Count
        folds_with_trades_min = $oosTrade20Count
        median_pf = $oosMedianPf
        min_pf = $oosMinPf
        max_dd_pct = $oosMaxDd
        aggregate_pf = $oosAggregatePf
        trades = $oosTrades
        net_profit = $oosNetProfit
        gross_profit = $oosGrossProfit
        gross_loss_abs = $oosGrossLossAbs
        win_rate_pct = $oosWinRate
    }
    execution_quality = [ordered]@{
        entry_attempts = $entryAttemptsTotal
        entry_success = $entrySuccessTotal
        entry_fail_total = $entryFailTotal
        entry_fail_no_money = $entryFailNoMoneyTotal
        entry_fail_other = $entryFailOtherTotal
        entry_fail_rate_pct = $entryFailRatePct
        no_money_fail_rate_pct = $noMoneyFailRatePct
    }
    folds = $rows
}

$summaryJsonPath = Join-Path $validationRootAbs "validation_summary.json"
$summaryCsvPath = Join-Path $validationRootAbs "validation_summary.csv"

$summary | ConvertTo-Json -Depth 8 | Set-Content -Path $summaryJsonPath -Encoding ASCII

$csvRows = foreach ($row in $rows) {
    [pscustomobject]@{
        fold_name = $row.fold_name
        kind = $row.kind
        is_oos = $row.is_oos
        from_date = $row.from_date
        to_date = $row.to_date
        status = $row.status
        pf = Format-Scalar -Value ([double]$row.pf)
        dd_pct = Format-Scalar -Value ([double]$row.dd_pct)
        trades = $row.trades
        net_profit = Format-Scalar -Value ([double]$row.net_profit)
        gross_profit = Format-Scalar -Value ([double]$row.gross_profit)
        gross_loss_abs = Format-Scalar -Value ([double]$row.gross_loss_abs)
        win_rate_pct = Format-Scalar -Value ([double]$row.win_rate_pct)
        entry_attempts = $row.entry_attempts
        entry_success = $row.entry_success
        entry_fail_no_money = $row.entry_fail_no_money
        entry_fail_other = $row.entry_fail_other
        entry_fail_rate_pct = Format-Scalar -Value ([double]$row.entry_fail_rate_pct)
        no_money_fail_rate_pct = Format-Scalar -Value ([double]$row.no_money_fail_rate_pct)
        consistency_ok = $row.consistency_ok
        notes = $row.notes
    }
}

$csvRows | Export-Csv -Path $summaryCsvPath -NoTypeInformation -Encoding ASCII

Write-Host ""
Write-Host "Validation complete."
Write-Host " Classification : $classification"
Write-Host " Summary JSON   : $summaryJsonPath"
Write-Host " Summary CSV    : $summaryCsvPath"
