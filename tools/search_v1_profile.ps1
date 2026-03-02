[CmdletBinding()]
param(
    [string]$OutputLabel = "",
    [string]$FromDate = "2025.08.01",
    [string]$ToDate = "2026.02.22",
    [switch]$CloseRunningTerminal
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

if ([string]::IsNullOrWhiteSpace($OutputLabel)) {
    $OutputLabel = "xauusd_v1_search_{0}" -f (Get-Date -Format "yyyyMMdd_HHmmss")
}

$repoRoot = Resolve-Path (Join-Path $PSScriptRoot "..")
$runScript = Join-Path $PSScriptRoot "run_mt5_backtest.ps1"
$researchRoot = Join-Path $repoRoot ("outputs\\research\\" + $OutputLabel)
$setsDir = Join-Path $researchRoot "sets"
$null = New-Item -Path $setsDir -ItemType Directory -Force

$baseSetPath = Join-Path $repoRoot "profiles\\xauusd_v1_volatilitytrend_default.set"
if (-not (Test-Path -Path $baseSetPath -PathType Leaf)) {
    throw "Base set file not found: $baseSetPath"
}

$baseMap = @{}
Get-Content -Path $baseSetPath | ForEach-Object {
    if ($_ -match "^\s*([A-Za-z0-9_]+)\s*=\s*(.*)\s*$") {
        $baseMap[$Matches[1]] = $Matches[2]
    }
}

function Parse-DoubleOrInf {
    param([string]$Text)
    if ($Text -eq "INF") { return [double]::PositiveInfinity }
    $value = 0.0
    if ([double]::TryParse($Text, [System.Globalization.NumberStyles]::Float, [System.Globalization.CultureInfo]::InvariantCulture, [ref]$value)) {
        return $value
    }
    return [double]::NaN
}

$trendPairs = @(
    @{ fast = 50; slow = 200 },
    @{ fast = 34; slow = 150 }
)

$atrSlValues = @(1.8, 2.4)
$atrTrailValues = @(1.2, 1.8)
$maxSpreadValues = @(100, 200, 350)
$timeProfiles = @(
    @{ use = "false"; start = 0; end = 24; tag = "all_day" },
    @{ use = "true"; start = 6; end = 20; tag = "eu_us" }
)

$results = New-Object System.Collections.Generic.List[object]
$index = 0

foreach ($pair in $trendPairs) {
    foreach ($slMult in $atrSlValues) {
        foreach ($trailMult in $atrTrailValues) {
            foreach ($spread in $maxSpreadValues) {
                foreach ($tp in $timeProfiles) {
                    $index++
                    $caseId = "c{0:D3}" -f $index
                    $setPath = Join-Path $setsDir ($caseId + ".set")

                    $map = @{}
                    foreach ($k in $baseMap.Keys) { $map[$k] = $baseMap[$k] }

                    $map["InpFastEMA_H4"] = "$($pair.fast)"
                    $map["InpSlowEMA_H4"] = "$($pair.slow)"
                    $map["InpATR_SL_Mult"] = ("{0:F2}" -f $slMult).Replace(",", ".")
                    $map["InpATR_Trail_Mult"] = ("{0:F2}" -f $trailMult).Replace(",", ".")
                    $map["InpMaxSpread"] = "$spread"
                    $map["InpUseTimeFilter"] = $tp.use
                    $map["InpStartHour"] = "$($tp.start)"
                    $map["InpEndHour"] = "$($tp.end)"

                    $lines = New-Object System.Collections.Generic.List[string]
                    foreach ($k in ($map.Keys | Sort-Object)) {
                        $lines.Add("$k=$($map[$k])")
                    }
                    Set-Content -Path $setPath -Value $lines -Encoding ASCII

                    $runLabel = "$OutputLabel`_$caseId"
                    Write-Host ("[{0}] Running {1}..." -f $caseId, $runLabel)

                    $args = @(
                        "-File", $runScript,
                        "-Expert", "XAUUSD_V1_VolatilityTrend.ex5",
                        "-ExpertLogPrefix", "XAUUSD_V1_VolatilityTrend",
                        "-SetFile", $setPath,
                        "-Symbol", "XAUUSD",
                        "-Timeframe", "H1",
                        "-FromDate", $FromDate,
                        "-ToDate", $ToDate,
                        "-RunLabel", $runLabel,
                        "-SplitTag", "search"
                    )
                    if ($CloseRunningTerminal.IsPresent) {
                        $args += "-CloseRunningTerminal"
                    }

                    & powershell @args | Out-Host

                    $runDir = Join-Path $repoRoot ("outputs\\mt5_runs\\" + $runLabel)
                    $xmlPath = Join-Path $runDir "mt5_report_fallback.xml"

                    $pf = [double]::NaN
                    $dd = [double]::NaN
                    $trades = 0
                    $net = [double]::NaN
                    $grossProfit = [double]::NaN
                    $grossLossAbs = [double]::NaN

                    if (Test-Path -Path $xmlPath -PathType Leaf) {
                        try {
                            [xml]$doc = Get-Content -Path $xmlPath -Raw
                            $pf = Parse-DoubleOrInf -Text ([string]$doc.mt5_report.profit_factor)
                            $dd = Parse-DoubleOrInf -Text ([string]$doc.mt5_report.drawdown_pct)
                            $trades = [int]([string]$doc.mt5_report.trades)
                            $net = Parse-DoubleOrInf -Text ([string]$doc.mt5_report.net_profit)
                            $grossProfit = Parse-DoubleOrInf -Text ([string]$doc.mt5_report.gross_profit)
                            $grossLossAbs = Parse-DoubleOrInf -Text ([string]$doc.mt5_report.gross_loss_abs)
                        } catch {
                            Write-Warning "Failed to parse fallback XML for $runLabel"
                        }
                    }

                    $results.Add([pscustomobject]@{
                        case_id = $caseId
                        run_label = $runLabel
                        from_date = $FromDate
                        to_date = $ToDate
                        ema_fast_h4 = $pair.fast
                        ema_slow_h4 = $pair.slow
                        atr_sl_mult = $slMult
                        atr_trail_mult = $trailMult
                        max_spread = $spread
                        use_time_filter = $tp.use
                        session_start = $tp.start
                        session_end = $tp.end
                        session_tag = $tp.tag
                        pf = $pf
                        dd_pct = $dd
                        trades = $trades
                        net_profit = $net
                        gross_profit = $grossProfit
                        gross_loss_abs = $grossLossAbs
                        set_file = $setPath
                        run_dir = $runDir
                    })
                }
            }
        }
    }
}

$sorted = $results | Sort-Object `
    @{ Expression = { if ([double]::IsNaN([double]$_.pf)) { -1.0 } elseif ([double]::IsInfinity([double]$_.pf)) { 1.0E9 } else { [double]$_.pf } }; Descending = $true }, `
    @{ Expression = { [int]$_.trades }; Descending = $true }, `
    @{ Expression = { if ([double]::IsNaN([double]$_.dd_pct)) { 1.0E9 } else { [double]$_.dd_pct } }; Descending = $false }, `
    @{ Expression = { if ([double]::IsNaN([double]$_.net_profit)) { -1.0E9 } else { [double]$_.net_profit } }; Descending = $true }

$csvPath = Join-Path $researchRoot "results.csv"
$jsonPath = Join-Path $researchRoot "results.json"
$summaryPath = Join-Path $researchRoot "summary.txt"

$sorted | Export-Csv -Path $csvPath -NoTypeInformation -Encoding ASCII
$sorted | ConvertTo-Json -Depth 6 | Set-Content -Path $jsonPath -Encoding ASCII

$top = @($sorted | Select-Object -First 10)
$target = @($sorted | Where-Object { $_.pf -ge 1.75 -and $_.trades -ge 20 -and $_.dd_pct -le 20.0 } | Select-Object -First 20)

$summary = New-Object System.Collections.Generic.List[string]
$summary.Add("label=$OutputLabel")
$summary.Add("cases=$($sorted.Count)")
$summary.Add("csv=$csvPath")
$summary.Add("json=$jsonPath")
$summary.Add("")
$summary.Add("Top 10 by PF/trades:")
foreach ($row in $top) {
    $summary.Add(("{0} pf={1} dd={2} trades={3} net={4} set={5}" -f
        $row.case_id, $row.pf, $row.dd_pct, $row.trades, $row.net_profit, $row.set_file))
}
$summary.Add("")
$summary.Add("Target hits (PF>=1.75, DD<=20, trades>=20): $($target.Count)")
foreach ($row in $target) {
    $summary.Add(("{0} pf={1} dd={2} trades={3} net={4}" -f
        $row.case_id, $row.pf, $row.dd_pct, $row.trades, $row.net_profit))
}

Set-Content -Path $summaryPath -Value $summary -Encoding ASCII
Write-Host "Wrote: $csvPath"
Write-Host "Wrote: $jsonPath"
Write-Host "Wrote: $summaryPath"
