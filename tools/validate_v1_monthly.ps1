[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [string]$SetFile,
    [string]$Symbol = "XAUUSD",
    [string]$Timeframe = "H1",
    [string]$Expert = "XAUUSD_V1_VolatilityTrend.ex5",
    [string]$ExpertLogPrefix = "XAUUSD_V1_VolatilityTrend",
    [string]$OutputLabel = "xauusd_v1_monthly_validation",
    [double]$Deposit = 10000.0,
    [int]$Leverage = 100,
    [switch]$CloseRunningTerminal,
    [switch]$RunDeterminism,
    [double]$ObjectiveRatio = 1.8,
    [double]$MonthlyPfMin = 1.75,
    [double]$MonthlyDdMax = 20.0,
    [int]$MonthlyTradesMin = 20,
    [int]$MonthsPassMin = 8,
    [int]$MonthsTradesMin = 10,
    [double]$CatastrophicDdMax = 30.0
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
    if ($python) { return $python.Source }

    $py = Get-Command py -ErrorAction SilentlyContinue
    if ($py) { return "$($py.Source) -3" }

    throw "Python executable not found (python/py)."
}

function Get-TradeLogMetrics {
    param([Parameter(Mandatory = $true)][string]$TradeLogPath)

    $styles = [System.Globalization.NumberStyles]::Float
    $culture = [System.Globalization.CultureInfo]::InvariantCulture

    $grossProfit = 0.0
    $grossLossAbs = 0.0
    $netProfit = 0.0
    $trades = 0
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
        if ($reasonText -notmatch "profit=([-+]?\d+(?:\.\d+)?)") {
            continue
        }

        $profit = [double]$Matches[1]
        $trades++
        $netProfit += $profit
        if ($profit -gt 0.0) {
            $grossProfit += $profit
        } elseif ($profit -lt 0.0) {
            $grossLossAbs += [Math]::Abs($profit)
        }
    }

    $profitFactor = 0.0
    if ($grossLossAbs -gt 0.0) {
        $profitFactor = $grossProfit / $grossLossAbs
    } elseif ($grossProfit -gt 0.0) {
        $profitFactor = [double]::PositiveInfinity
    }

    return [ordered]@{
        pf = $profitFactor
        dd_pct = $maxDrawdownPct
        trades = $trades
        net_profit = $netProfit
        gross_profit = $grossProfit
        gross_loss_abs = $grossLossAbs
    }
}

function Get-MonthMatrix {
    param(
        [datetime]$StartMonth,
        [int]$Count
    )

    $rows = New-Object System.Collections.Generic.List[object]
    for ($i = 0; $i -lt $Count; $i++) {
        $monthStart = $StartMonth.AddMonths($i)
        $monthEnd = $monthStart.AddMonths(1).AddDays(-1)
        $key = $monthStart.ToString("yyyy-MM")
        $rows.Add([ordered]@{
            key = $key
            from = $monthStart.ToString("yyyy.MM.dd")
            to = $monthEnd.ToString("yyyy.MM.dd")
            run_name = ("month_{0}" -f $monthStart.ToString("yyyy_MM"))
        })
    }

    return $rows
}

$repoRoot = Resolve-AbsolutePath -PathValue (Join-Path $PSScriptRoot "..")
$runScript = Resolve-AbsolutePath -PathValue (Join-Path $PSScriptRoot "run_mt5_backtest.ps1")
$scoreScript = Resolve-AbsolutePath -PathValue (Join-Path $PSScriptRoot "score_monthly.py")
$setFileAbs = Resolve-AbsolutePath -PathValue $SetFile
$pythonCmd = Get-PythonCommand

$validationRootRel = Join-Path "outputs\validation" $OutputLabel
$validationRootAbs = Join-Path $repoRoot $validationRootRel
$null = New-Item -Path $validationRootAbs -ItemType Directory -Force

$monthMatrix = Get-MonthMatrix -StartMonth ([datetime]::Parse("2025-02-01")) -Count 12
$rows = New-Object System.Collections.Generic.List[object]

foreach ($month in $monthMatrix) {
    $runName = [string]$month.run_name
    $fromDate = [string]$month.from
    $toDate = [string]$month.to

    Write-Host ("[{0}] Running {1} ({2} -> {3})" -f (Get-Date -Format "HH:mm:ss"), $runName, $fromDate, $toDate)

    $monthRootRel = Join-Path $validationRootRel $runName
    $runParams = @{
        SetFile = $setFileAbs
        Symbol = $Symbol
        Timeframe = $Timeframe
        Expert = $Expert
        ExpertLogPrefix = $ExpertLogPrefix
        FromDate = $fromDate
        ToDate = $toDate
        Deposit = $Deposit
        Leverage = $Leverage
        OutputRoot = $monthRootRel
        RunLabel = $runName
        SplitTag = $runName
    }
    if ($CloseRunningTerminal.IsPresent) {
        $runParams.CloseRunningTerminal = $true
    }

    & $runScript @runParams

    $runDir = Join-Path $repoRoot (Join-Path $monthRootRel $runName)
    $metadataPath = Join-Path $runDir "run_metadata.json"

    $status = "ok"
    $pf = [double]::NaN
    $ddPct = [double]::NaN
    $trades = 0
    $netProfit = 0.0
    $grossProfit = 0.0
    $grossLossAbs = 0.0
    $balanceRatio = [double]::NaN

    if (-not (Test-Path -Path $metadataPath -PathType Leaf)) {
        $status = "insufficient_data"
    } else {
        $metadata = Get-Content -Path $metadataPath -Raw | ConvertFrom-Json
        $tradeLogPath = [string]$metadata.trade_log_csv

        if ([string]::IsNullOrWhiteSpace($tradeLogPath) -or -not (Test-Path -Path $tradeLogPath -PathType Leaf)) {
            $status = "insufficient_data"
        } else {
            $metrics = Get-TradeLogMetrics -TradeLogPath $tradeLogPath
            $pf = [double]$metrics.pf
            $ddPct = [double]$metrics.dd_pct
            $trades = [int]$metrics.trades
            $netProfit = [double]$metrics.net_profit
            $grossProfit = [double]$metrics.gross_profit
            $grossLossAbs = [double]$metrics.gross_loss_abs
            $balanceRatio = ($Deposit + $netProfit) / $Deposit

            if ($trades -le 0) {
                $status = "insufficient_data"
            }
        }
    }

    $rows.Add([pscustomobject]@{
        month_key = [string]$month.key
        from_date = $fromDate
        to_date = $toDate
        status = $status
        pf = $pf
        dd_pct = $ddPct
        trades = $trades
        net_profit = $netProfit
        gross_profit = $grossProfit
        gross_loss_abs = $grossLossAbs
        balance_ratio = $balanceRatio
        run_dir = $runDir
    })
}

$rawCsvPath = Join-Path $validationRootAbs "monthly_runs.csv"
$rows | Export-Csv -Path $rawCsvPath -NoTypeInformation -Encoding ASCII

$determinismDrift = [double]::NaN
if ($RunDeterminism.IsPresent) {
    $drifts = New-Object System.Collections.Generic.List[double]

    foreach ($row in $rows) {
        if ([string]$row.status -ne "ok") {
            continue
        }

        $month = $monthMatrix | Where-Object { $_.key -eq [string]$row.month_key } | Select-Object -First 1
        if (-not $month) {
            continue
        }

        $repeatRunName = "{0}_repeat" -f [string]$month.run_name
        Write-Host ("[{0}] Determinism rerun {1}" -f (Get-Date -Format "HH:mm:ss"), $repeatRunName)

        $repeatRootRel = Join-Path $validationRootRel $repeatRunName
        $repeatParams = @{
            SetFile = $setFileAbs
            Symbol = $Symbol
            Timeframe = $Timeframe
            Expert = $Expert
            ExpertLogPrefix = $ExpertLogPrefix
            FromDate = [string]$month.from
            ToDate = [string]$month.to
            Deposit = $Deposit
            Leverage = $Leverage
            OutputRoot = $repeatRootRel
            RunLabel = $repeatRunName
            SplitTag = $repeatRunName
        }
        if ($CloseRunningTerminal.IsPresent) {
            $repeatParams.CloseRunningTerminal = $true
        }

        & $runScript @repeatParams

        $repeatDir = Join-Path $repoRoot (Join-Path $repeatRootRel $repeatRunName)
        $repeatMeta = Join-Path $repeatDir "run_metadata.json"
        if (-not (Test-Path -Path $repeatMeta -PathType Leaf)) {
            continue
        }

        $metaObj = Get-Content -Path $repeatMeta -Raw | ConvertFrom-Json
        $repeatLog = [string]$metaObj.trade_log_csv
        if ([string]::IsNullOrWhiteSpace($repeatLog) -or -not (Test-Path -Path $repeatLog -PathType Leaf)) {
            continue
        }

        $repeatMetrics = Get-TradeLogMetrics -TradeLogPath $repeatLog
        if ([int]$repeatMetrics.trades -le 0) {
            continue
        }

        $basePf = [double]$row.pf
        $repeatPf = [double]$repeatMetrics.pf
        if ([double]::IsNaN($basePf) -or [double]::IsNaN($repeatPf) -or [double]::IsInfinity($basePf) -or [double]::IsInfinity($repeatPf)) {
            continue
        }

        $drifts.Add([Math]::Abs($basePf - $repeatPf))
    }

    if ($drifts.Count -gt 0) {
        $sum = 0.0
        foreach ($d in $drifts) { $sum += $d }
        $determinismDrift = $sum / $drifts.Count
    }
}

$summaryJsonPath = Join-Path $validationRootAbs "validation_summary.json"
$summaryCsvPath = Join-Path $validationRootAbs "validation_summary.csv"

$scoreArgs = @(
    $scoreScript,
    "--input-csv", $rawCsvPath,
    "--output-json", $summaryJsonPath,
    "--output-csv", $summaryCsvPath,
    "--objective-ratio", $ObjectiveRatio,
    "--pf-min", $MonthlyPfMin,
    "--dd-max", $MonthlyDdMax,
    "--trades-min", $MonthlyTradesMin,
    "--months-pass-min", $MonthsPassMin,
    "--months-total", 12,
    "--months-trades-min", $MonthsTradesMin,
    "--catastrophic-dd-max", $CatastrophicDdMax,
    "--determinism-avg-drift", $determinismDrift
)

& $pythonCmd @scoreArgs | Out-Host

if (Test-Path -Path $summaryJsonPath -PathType Leaf) {
    $summary = Get-Content -Path $summaryJsonPath -Raw | ConvertFrom-Json
    $summary | Add-Member -NotePropertyName "profile_set" -NotePropertyValue $setFileAbs -Force
    $summary | Add-Member -NotePropertyName "symbol" -NotePropertyValue $Symbol -Force
    $summary | Add-Member -NotePropertyName "timeframe" -NotePropertyValue $Timeframe -Force
    $summary | Add-Member -NotePropertyName "expert" -NotePropertyValue $Expert -Force
    $summary | Add-Member -NotePropertyName "expert_log_prefix" -NotePropertyValue $ExpertLogPrefix -Force
    $summary | Add-Member -NotePropertyName "created_utc" -NotePropertyValue ((Get-Date).ToUniversalTime().ToString("o")) -Force
    $summary | ConvertTo-Json -Depth 8 | Set-Content -Path $summaryJsonPath -Encoding ASCII

    Write-Host ""
    Write-Host "Validation complete."
    Write-Host (" Classification : {0}" -f [string]$summary.classification)
    Write-Host (" Months passed  : {0}/{1}" -f [int]$summary.months_passed, [int]$summary.months_total)
    Write-Host (" Summary JSON   : {0}" -f $summaryJsonPath)
    Write-Host (" Summary CSV    : {0}" -f $summaryCsvPath)
}
