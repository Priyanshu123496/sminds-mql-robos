[CmdletBinding()]
param(
    [string]$BaseSetFile = "outputs/research/xauusd_h1_ema_prod_r5/sets/c004_stoptarget_st450_28.set",
    [string]$Symbol = "XAUUSD",
    [string]$Timeframe = "H1",
    [string]$Expert = "XAUUSD_H1_EMACrossReversal.ex5",
    [string]$ExpertLogPrefix = "XAUUSD_H1_EMACrossReversal",
    [string]$FromDate = "2025.08.01",
    [string]$ToDate = "2026.02.22",
    [string]$OutputLabel = "xauusd_h1_confirm_sweep",
    [switch]$CloseRunningTerminal
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

function Resolve-AbsolutePath {
    param([Parameter(Mandatory = $true)][string]$PathValue)
    return (Resolve-Path -Path $PathValue -ErrorAction Stop).ProviderPath
}

function Read-SetFile {
    param([Parameter(Mandatory = $true)][string]$Path)
    $map = @{}
    foreach ($lineRaw in (Get-Content -Path $Path -Encoding ASCII)) {
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

function Get-TradeMetrics {
    param([Parameter(Mandatory = $true)][string]$TradeLogPath)

    if (-not (Test-Path -Path $TradeLogPath -PathType Leaf)) {
        return [ordered]@{
            pf = [double]::NaN
            trades = 0
            net_profit = 0.0
            gross_profit = 0.0
            gross_loss_abs = 0.0
        }
    }

    $grossProfit = 0.0
    $grossLossAbs = 0.0
    $netProfit = 0.0
    $trades = 0

    $rows = Import-Csv -Path $TradeLogPath -Delimiter ';'
    foreach ($row in $rows) {
        if ([string]$row.event -ne "DEAL_OUT") { continue }
        $reasonText = [string]$row.reason
        if ($reasonText -notmatch "profit=([-+]?\d+(?:\.\d+)?)") { continue }
        $profit = [double]$Matches[1]
        $trades++
        $netProfit += $profit
        if ($profit > 0.0) {
            $grossProfit += $profit
        } elseif ($profit -lt 0.0) {
            $grossLossAbs += [Math]::Abs($profit)
        }
    }

    $pf = 0.0
    if ($grossLossAbs -gt 0.0) {
        $pf = $grossProfit / $grossLossAbs
    } elseif ($grossProfit -gt 0.0) {
        $pf = [double]::PositiveInfinity
    }

    return [ordered]@{
        pf = $pf
        trades = $trades
        net_profit = $netProfit
        gross_profit = $grossProfit
        gross_loss_abs = $grossLossAbs
    }
}

$repoRoot = Resolve-AbsolutePath -PathValue (Join-Path $PSScriptRoot "..")
$runScript = Resolve-AbsolutePath -PathValue (Join-Path $PSScriptRoot "run_mt5_backtest.ps1")
$baseSetAbs = Resolve-AbsolutePath -PathValue $BaseSetFile

$rootRel = Join-Path "outputs\research" $OutputLabel
$rootAbs = Join-Path $repoRoot $rootRel
$setDir = Join-Path $rootAbs "sets"
$null = New-Item -Path $setDir -ItemType Directory -Force

$baseMap = Read-SetFile -Path $baseSetAbs
$results = New-Object System.Collections.Generic.List[object]

$emaOptions = @(
    @{ fast = "18"; slow = "45"; id = "f18s45" },
    @{ fast = "20"; slow = "50"; id = "f20s50" },
    @{ fast = "22"; slow = "55"; id = "f22s55" }
)
$regimePeriods = @("150", "200")
$slopeBarsOptions = @("2", "3")
$slopeOptions = @("0.000", "0.005", "0.010", "0.015", "0.020", "0.030")

$cases = New-Object System.Collections.Generic.List[object]
$idx = 0

foreach ($ema in $emaOptions) {
    # Regime on variants
    foreach ($rp in $regimePeriods) {
        foreach ($sb in $slopeBarsOptions) {
            foreach ($sl in $slopeOptions) {
                $idx++
                $cases.Add([ordered]@{
                    id = ("c{0:D3}_{1}_rp{2}_sb{3}_sl{4}" -f $idx, $ema.id, $rp, $sb, ($sl -replace '\.', ''))
                    EmaFast = $ema.fast
                    EmaSlow = $ema.slow
                    UseTrendRegimeFilter = "true"
                    RegimeEmaPeriod = $rp
                    RequireRegimeSlope = "true"
                    RegimeSlopeBars = $sb
                    MinRegimeSlopeAtr = $sl
                    UseNewsFilter = "false"
                    UseCooldownAfterLoss = "false"
                    CooldownBarsAfterLoss = "0"
                })
            }
        }
    }

    # Regime off baseline for this EMA pair
    $idx++
    $cases.Add([ordered]@{
        id = ("c{0:D3}_{1}_rgoff" -f $idx, $ema.id)
        EmaFast = $ema.fast
        EmaSlow = $ema.slow
        UseTrendRegimeFilter = "false"
        UseNewsFilter = "false"
        UseCooldownAfterLoss = "false"
        CooldownBarsAfterLoss = "0"
    })
}

Write-Host ("Running {0} confirm-window cases..." -f $cases.Count)

foreach ($case in $cases) {
    $caseId = [string]$case.id
    $setMap = @{}
    foreach ($k in $baseMap.Keys) { $setMap[$k] = $baseMap[$k] }
    foreach ($k in $case.Keys) {
        if ($k -eq "id") { continue }
        $setMap[$k] = [string]$case[$k]
    }

    $setPath = Join-Path $setDir ($caseId + ".set")
    Write-SetFile -Map $setMap -Path $setPath

    $outRel = Join-Path $rootRel "runs"
    $runParams = @{
        SetFile = $setPath
        Symbol = $Symbol
        Timeframe = $Timeframe
        Expert = $Expert
        ExpertLogPrefix = $ExpertLogPrefix
        FromDate = $FromDate
        ToDate = $ToDate
        OutputRoot = $outRel
        RunLabel = $caseId
        SplitTag = $caseId
    }
    if ($CloseRunningTerminal.IsPresent) { $runParams.CloseRunningTerminal = $true }
    & $runScript @runParams | Out-Null

    $metaPath = Join-Path $repoRoot (Join-Path $outRel ($caseId + "\run_metadata.json"))
    $tradeLog = $null
    if (Test-Path -Path $metaPath -PathType Leaf) {
        $meta = Get-Content -Path $metaPath -Raw | ConvertFrom-Json
        $tradeLog = [string]$meta.trade_log_csv
    }

    $m = Get-TradeMetrics -TradeLogPath $tradeLog
    $results.Add([pscustomobject]@{
        case_id = $caseId
        set_file = $setPath
        confirm_pf = $m.pf
        confirm_trades = $m.trades
        net_profit = $m.net_profit
        gross_profit = $m.gross_profit
        gross_loss_abs = $m.gross_loss_abs
        UseTrendRegimeFilter = $setMap["UseTrendRegimeFilter"]
        MinRegimeSlopeAtr = $setMap["MinRegimeSlopeAtr"]
        RegimeEmaPeriod = $setMap["RegimeEmaPeriod"]
        RegimeSlopeBars = $setMap["RegimeSlopeBars"]
        EmaFast = $setMap["EmaFast"]
        EmaSlow = $setMap["EmaSlow"]
    })
}

$resultsCsv = Join-Path $rootAbs "results.csv"
$resultsJson = Join-Path $rootAbs "results.json"
$results | Export-Csv -Path $resultsCsv -NoTypeInformation -Encoding ASCII
$results | ConvertTo-Json -Depth 6 | Set-Content -Path $resultsJson -Encoding ASCII

$bestPf = $results | Where-Object { -not [double]::IsNaN($_.confirm_pf) } | Sort-Object confirm_pf -Descending | Select-Object -First 10
$bestTrades = $results |
    Sort-Object @{ Expression = "confirm_trades"; Descending = $true }, @{ Expression = "confirm_pf"; Descending = $true } |
    Select-Object -First 10
$target = $results |
    Where-Object { $_.confirm_pf -ge 1.75 -and $_.confirm_trades -ge 8 } |
    Sort-Object @{ Expression = "confirm_pf"; Descending = $true }, @{ Expression = "confirm_trades"; Descending = $true } |
    Select-Object -First 10

Write-Host ""
Write-Host "Sweep complete."
Write-Host (" Results CSV: {0}" -f $resultsCsv)
Write-Host (" Results JSON: {0}" -f $resultsJson)
Write-Host ""
Write-Host "Top PF:"
$bestPf | Format-Table case_id,confirm_pf,confirm_trades,net_profit,EmaFast,EmaSlow,UseTrendRegimeFilter,MinRegimeSlopeAtr -AutoSize | Out-Host
Write-Host ""
Write-Host "Top Trades:"
$bestTrades | Format-Table case_id,confirm_pf,confirm_trades,net_profit,EmaFast,EmaSlow,UseTrendRegimeFilter,MinRegimeSlopeAtr -AutoSize | Out-Host
Write-Host ""
Write-Host "Target hits (PF>=1.75 and trades>=8):"
if ($target -and $target.Count -gt 0) {
    $target | Format-Table case_id,confirm_pf,confirm_trades,net_profit,EmaFast,EmaSlow,UseTrendRegimeFilter,MinRegimeSlopeAtr -AutoSize | Out-Host
} else {
    Write-Host "None"
}
