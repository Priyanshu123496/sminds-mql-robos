[CmdletBinding()]
param(
    [string]$TerminalPath = "C:\Program Files\MetaTrader 5\terminal64.exe",
    [string]$Expert = "XAUUSD_RobustBreakout.ex5",
    [string]$ExpertLogPrefix = "XAUUSD_RobustBreakout",
    [Parameter(Mandatory = $true)]
    [string]$SetFile,
    [string]$Symbol = "XAUUSD",
    [string]$Timeframe = "M15",
    [Parameter(Mandatory = $true)]
    [string]$FromDate,
    [Parameter(Mandatory = $true)]
    [string]$ToDate,
    [double]$Deposit = 10000.0,
    [int]$Leverage = 100,
    [string]$Spread = "Current",
    [int]$Model = 4,
    [string]$Currency = "USD",
    [string]$OutputRoot = "outputs\mt5_runs",
    [string]$RunLabel = "",
    [string]$SplitTag = "baseline",
    [switch]$CloseRunningTerminal,
    [switch]$Portable
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

function Resolve-AbsolutePath {
    param([Parameter(Mandatory = $true)][string]$PathValue)
    $resolved = Resolve-Path -Path $PathValue -ErrorAction Stop
    return $resolved.ProviderPath
}

function Get-GitCommit {
    param([Parameter(Mandatory = $true)][string]$RepoRoot)
    try {
        if (-not (Get-Command git -ErrorAction SilentlyContinue)) {
            return $null
        }
        $hash = git -C $RepoRoot rev-parse HEAD 2>$null
        if ($LASTEXITCODE -eq 0 -and $hash) {
            return $hash.Trim()
        }
    } catch {
        return $null
    }
    return $null
}

function Resolve-TerminalDataDir {
    param(
        [Parameter(Mandatory = $true)][string]$TerminalRoot,
        [Parameter(Mandatory = $true)][string]$ExpertFileName
    )

    if (-not (Test-Path -Path $TerminalRoot -PathType Container)) {
        return $null
    }

    $dirs = Get-ChildItem -Path $TerminalRoot -Directory -ErrorAction SilentlyContinue
    if (-not $dirs) {
        return $null
    }

    $withExpert = @()
    foreach ($dir in $dirs) {
        $expertPath = Join-Path $dir.FullName ("MQL5\\Experts\\" + $ExpertFileName)
        if (Test-Path -Path $expertPath -PathType Leaf) {
            $withExpert += $dir
        }
    }

    if ($withExpert.Count -gt 0) {
        return ($withExpert | Sort-Object LastWriteTimeUtc -Descending | Select-Object -First 1).FullName
    }

    return ($dirs | Sort-Object LastWriteTimeUtc -Descending | Select-Object -First 1).FullName
}

function Resolve-ExpertBinaryPath {
    param(
        [Parameter(Mandatory = $true)][string]$RepoRoot,
        [Parameter(Mandatory = $true)][string]$ExpertArg
    )

    $expertName = [System.IO.Path]::GetFileName($ExpertArg)
    $candidates = New-Object System.Collections.Generic.List[string]

    if ([System.IO.Path]::IsPathRooted($ExpertArg)) {
        $candidates.Add($ExpertArg)
    }

    $candidates.Add((Join-Path $RepoRoot ("Experts\" + $expertName)))

    foreach ($candidate in $candidates) {
        if ([string]::IsNullOrWhiteSpace($candidate)) {
            continue
        }
        if (Test-Path -Path $candidate -PathType Leaf) {
            return (Resolve-Path -Path $candidate -ErrorAction Stop).ProviderPath
        }
    }

    return $null
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
        profit_factor = $profitFactor
        drawdown_pct = $maxDrawdownPct
        trades = $trades
        net_profit = $netProfit
        gross_profit = $grossProfit
        gross_loss_abs = $grossLossAbs
    }
}

if (-not (Test-Path -Path $TerminalPath -PathType Leaf)) {
    throw "MT5 terminal not found at: $TerminalPath"
}

$runningTerminals = Get-Process -Name "terminal64" -ErrorAction SilentlyContinue |
    Where-Object { $_.Path -and $_.Path -ieq $TerminalPath }

if ($runningTerminals) {
    if ($CloseRunningTerminal.IsPresent) {
        Write-Host "Closing existing MT5 terminal process(es) for deterministic /config execution..."
        foreach ($proc in $runningTerminals) {
            Stop-Process -Id $proc.Id -Force
        }
        Start-Sleep -Seconds 2
    } else {
        Write-Warning "MT5 terminal is already running. /config backtests may be ignored by an existing instance."
        Write-Warning "Close MT5 manually or rerun this script with -CloseRunningTerminal."
    }
}

$resolvedSetFile = Resolve-AbsolutePath -PathValue $SetFile

$repoRoot = Resolve-AbsolutePath -PathValue (Join-Path $PSScriptRoot "..")
$terminalRoot = Join-Path $env:APPDATA "MetaQuotes\Terminal"
$expertFileName = [System.IO.Path]::GetFileName($Expert)
$terminalDataDir = Resolve-TerminalDataDir -TerminalRoot $terminalRoot -ExpertFileName $expertFileName
$expertSourcePath = Resolve-ExpertBinaryPath -RepoRoot $repoRoot -ExpertArg $Expert
if (-not $expertSourcePath) {
    throw "Expert binary not found. Provide compiled file as absolute path or place it at Experts\$expertFileName"
}
if (-not $terminalDataDir) {
    throw "Unable to resolve MT5 terminal data directory under $terminalRoot"
}

$terminalExpertsDir = Join-Path $terminalDataDir "MQL5\Experts"
$null = New-Item -Path $terminalExpertsDir -ItemType Directory -Force
$expertTargetPath = Join-Path $terminalExpertsDir $expertFileName
Copy-Item -Path $expertSourcePath -Destination $expertTargetPath -Force
$expertForTester = $expertFileName

if ([string]::IsNullOrWhiteSpace($RunLabel)) {
    $RunLabel = "run_{0}" -f (Get-Date -Format "yyyyMMdd_HHmmss")
}

$outputRootAbs = Resolve-Path -Path "." | Select-Object -ExpandProperty Path
$outputRootAbs = Join-Path $outputRootAbs $OutputRoot
$null = New-Item -Path $outputRootAbs -ItemType Directory -Force

$runDir = Join-Path $outputRootAbs $RunLabel
$null = New-Item -Path $runDir -ItemType Directory -Force

$safeRunLabel = ($RunLabel -replace "[^A-Za-z0-9_-]", "_")
$reportBase = "mt5_report_$safeRunLabel"
$configPath = Join-Path $runDir "tester.ini"

$profilesTesterDir = $null
$setFileForTester = $resolvedSetFile
$setFileParam = $resolvedSetFile
if ($terminalDataDir) {
    $profilesTesterDir = Join-Path $terminalDataDir "MQL5\Profiles\Tester"
    $null = New-Item -Path $profilesTesterDir -ItemType Directory -Force
    $setBasename = "__codex_$safeRunLabel.set"
    $setFileForTester = Join-Path $profilesTesterDir $setBasename
    $setFileParam = $setBasename
    Copy-Item -Path $resolvedSetFile -Destination $setFileForTester -Force
}

$configContent = @(
    "[Tester]",
    "Expert=$expertForTester",
    "ExpertParameters=$setFileParam",
    "Symbol=$Symbol",
    "Period=$Timeframe",
    "Model=$Model",
    "Optimization=0",
    "FromDate=$FromDate",
    "ToDate=$ToDate",
    "ForwardMode=0",
    "Deposit=$Deposit",
    "Currency=$Currency",
    "Leverage=1:$Leverage",
    "Spread=$Spread",
    "Report=$reportBase",
    "ReplaceReport=1",
    "ShutdownTerminal=1",
    "Visual=0"
) -join [Environment]::NewLine

Set-Content -Path $configPath -Value $configContent -Encoding ASCII
$configHash = (Get-FileHash -Path $configPath -Algorithm SHA256).Hash

$commonFilesDir = Join-Path $env:APPDATA "MetaQuotes\Terminal\Common\Files"
$startUtc = (Get-Date).ToUniversalTime()

$args = @("/config:$configPath")
$args += "/report:$reportBase"
if ($Portable.IsPresent) {
    $args += "/portable"
}

Write-Host "Starting MT5 backtest..."
Write-Host " Terminal : $TerminalPath"
Write-Host " Config   : $configPath"
Write-Host " Run dir  : $runDir"

$proc = Start-Process -FilePath $TerminalPath -ArgumentList $args -PassThru -Wait
$endUtc = (Get-Date).ToUniversalTime()
$durationSec = [Math]::Round(($endUtc - $startUtc).TotalSeconds, 2)
$exitCode = $proc.ExitCode

$xmlReport = Get-ChildItem -Path $runDir -Filter "mt5_report*.xml" -File -ErrorAction SilentlyContinue |
    Sort-Object LastWriteTimeUtc -Descending |
    Select-Object -First 1

$htmlReport = Get-ChildItem -Path $runDir -File -ErrorAction SilentlyContinue |
    Where-Object { $_.Name -like "mt5_report*.htm" -or $_.Name -like "mt5_report*.html" } |
    Sort-Object LastWriteTimeUtc -Descending |
    Select-Object -First 1

if ((-not $xmlReport -or -not $htmlReport) -and (Test-Path -Path $terminalRoot -PathType Container)) {
    $externalReports = Get-ChildItem -Path $terminalRoot -Recurse -File -ErrorAction SilentlyContinue |
        Where-Object {
            $_.LastWriteTimeUtc -ge $startUtc.AddMinutes(-5) -and
            (
                $_.Name -like "$reportBase*.xml" -or
                $_.Name -like "$reportBase*.htm" -or
                $_.Name -like "$reportBase*.html"
            )
        } |
        Sort-Object LastWriteTimeUtc -Descending

    foreach ($reportFile in $externalReports) {
        $targetReportPath = Join-Path $runDir $reportFile.Name
        if ($reportFile.FullName -ne $targetReportPath) {
            Copy-Item -Path $reportFile.FullName -Destination $targetReportPath -Force
        }
    }

    $xmlReport = Get-ChildItem -Path $runDir -Filter "mt5_report*.xml" -File -ErrorAction SilentlyContinue |
        Sort-Object LastWriteTimeUtc -Descending |
        Select-Object -First 1

    $htmlReport = Get-ChildItem -Path $runDir -File -ErrorAction SilentlyContinue |
        Where-Object { $_.Name -like "mt5_report*.htm" -or $_.Name -like "mt5_report*.html" } |
        Sort-Object LastWriteTimeUtc -Descending |
        Select-Object -First 1
}

$tradeLogOut = $null
if (Test-Path -Path $commonFilesDir -PathType Container) {
    $logCandidates = Get-ChildItem -Path $commonFilesDir -Filter "$ExpertLogPrefix`_*.csv" -File -ErrorAction SilentlyContinue |
        Where-Object { $_.LastWriteTimeUtc -ge $startUtc.AddMinutes(-2) } |
        Sort-Object LastWriteTimeUtc -Descending
    if ($logCandidates) {
        $sourceLog = $logCandidates | Select-Object -First 1
        $tradeLogOut = Join-Path $runDir "trade_log.csv"
        Copy-Item -Path $sourceLog.FullName -Destination $tradeLogOut -Force
    }
}

$reportFallbackGenerated = $false
if ((-not $xmlReport -or -not $htmlReport) -and $tradeLogOut -and (Test-Path -Path $tradeLogOut -PathType Leaf)) {
    $fallback = Get-TradeLogMetrics -TradeLogPath $tradeLogOut

    if (-not $xmlReport) {
        $pfValue = if ([double]::IsInfinity([double]$fallback.profit_factor)) { "INF" } else { "{0:F6}" -f [double]$fallback.profit_factor }
        $xmlFallbackPath = Join-Path $runDir "mt5_report_fallback.xml"
        $xmlContent = @"
<mt5_report source="trade_log_fallback">
  <profit_factor>$pfValue</profit_factor>
  <drawdown_pct>{0:F6}</drawdown_pct>
  <trades>{1}</trades>
  <net_profit>{2:F2}</net_profit>
  <gross_profit>{3:F2}</gross_profit>
  <gross_loss_abs>{4:F2}</gross_loss_abs>
</mt5_report>
"@ -f [double]$fallback.drawdown_pct, [int]$fallback.trades, [double]$fallback.net_profit, [double]$fallback.gross_profit, [double]$fallback.gross_loss_abs
        Set-Content -Path $xmlFallbackPath -Value $xmlContent -Encoding ASCII
        $xmlReport = Get-Item $xmlFallbackPath
        $reportFallbackGenerated = $true
    }

    if (-not $htmlReport) {
        $pfText = if ([double]::IsInfinity([double]$fallback.profit_factor)) { "INF" } else { "{0:F6}" -f [double]$fallback.profit_factor }
        $htmlFallbackPath = Join-Path $runDir "mt5_report_fallback.html"
        $htmlContent = @"
<html>
<head><meta charset="utf-8"><title>MT5 Report Fallback</title></head>
<body>
<h2>MT5 Report Fallback (trade_log.csv)</h2>
<table border="1" cellpadding="4" cellspacing="0">
  <tr><td>Profit Factor</td><td>$pfText</td></tr>
  <tr><td>Drawdown %</td><td>{0:F6}</td></tr>
  <tr><td>Trades</td><td>{1}</td></tr>
  <tr><td>Net Profit</td><td>{2:F2}</td></tr>
  <tr><td>Gross Profit</td><td>{3:F2}</td></tr>
  <tr><td>Gross Loss Abs</td><td>{4:F2}</td></tr>
</table>
</body>
</html>
"@ -f [double]$fallback.drawdown_pct, [int]$fallback.trades, [double]$fallback.net_profit, [double]$fallback.gross_profit, [double]$fallback.gross_loss_abs
        Set-Content -Path $htmlFallbackPath -Value $htmlContent -Encoding ASCII
        $htmlReport = Get-Item $htmlFallbackPath
        $reportFallbackGenerated = $true
    }
}

$testerJournalOut = $null
if (Test-Path -Path $terminalRoot -PathType Container) {
    $testerLogCandidates = @()
    Get-ChildItem -Path $terminalRoot -Directory -ErrorAction SilentlyContinue | ForEach-Object {
        $testerLogDir = Join-Path $_.FullName "Tester\logs"
        if (Test-Path -Path $testerLogDir -PathType Container) {
            $testerLogCandidates += Get-ChildItem -Path $testerLogDir -Filter "*.log" -File -ErrorAction SilentlyContinue
        }
    }
    $latestTesterLog = $testerLogCandidates |
        Where-Object { $_.LastWriteTimeUtc -ge $startUtc.AddMinutes(-5) } |
        Sort-Object LastWriteTimeUtc -Descending |
        Select-Object -First 1
    if ($latestTesterLog) {
        $testerJournalOut = Join-Path $runDir "tester_journal.log"
        Copy-Item -Path $latestTesterLog.FullName -Destination $testerJournalOut -Force
    }
}

$agentTesterLogOut = $null
$agentRoot = Join-Path $env:APPDATA "MetaQuotes\Tester"
if (Test-Path -Path $agentRoot -PathType Container) {
    $agentLogs = Get-ChildItem -Path $agentRoot -Recurse -Filter "*.log" -File -ErrorAction SilentlyContinue |
        Where-Object { $_.FullName -like "*Agent-*\\logs\\*" -and $_.LastWriteTimeUtc -ge $startUtc.AddMinutes(-5) } |
        Sort-Object LastWriteTimeUtc -Descending
    if ($agentLogs) {
        $agentTesterLogOut = Join-Path $runDir "tester_agent.log"
        Copy-Item -Path ($agentLogs | Select-Object -First 1).FullName -Destination $agentTesterLogOut -Force
    }
}

$metadata = [ordered]@{
    run_label = $RunLabel
    split_tag = $SplitTag
    started_utc = $startUtc.ToString("o")
    finished_utc = $endUtc.ToString("o")
    duration_seconds = $durationSec
    terminal_exit_code = $exitCode
    terminal_path = $TerminalPath
    terminal_data_dir = $terminalDataDir
    expert = $Expert
    expert_for_tester = $expertForTester
    expert_source_file = $expertSourcePath
    expert_target_file = $expertTargetPath
    expert_log_prefix = $ExpertLogPrefix
    set_file = $resolvedSetFile
    set_file_for_tester = $setFileForTester
    symbol = $Symbol
    timeframe = $Timeframe
    from_date = $FromDate
    to_date = $ToDate
    deposit = $Deposit
    leverage = $Leverage
    spread = $Spread
    model = $Model
    report_xml = if ($xmlReport) { $xmlReport.FullName } else { $null }
    report_html = if ($htmlReport) { $htmlReport.FullName } else { $null }
    report_fallback_generated = $reportFallbackGenerated
    trade_log_csv = $tradeLogOut
    tester_journal_log = $testerJournalOut
    tester_agent_log = $agentTesterLogOut
    config_file = $configPath
    config_sha256 = $configHash
    git_commit = Get-GitCommit -RepoRoot $repoRoot
}

$metadataPath = Join-Path $runDir "run_metadata.json"
$metadata | ConvertTo-Json -Depth 6 | Set-Content -Path $metadataPath -Encoding ASCII

Write-Host "Finished MT5 run."
Write-Host " Exit code : $exitCode"
Write-Host " Duration  : $durationSec sec"
Write-Host " XML report: $($metadata.report_xml)"
Write-Host " HTML report: $($metadata.report_html)"
Write-Host " Trade log : $($metadata.trade_log_csv)"
Write-Host " Metadata  : $metadataPath"

if (-not $metadata.report_xml -and -not $metadata.report_html) {
    Write-Warning "No report files were detected. Verify MT5 was closed before launch and that tester execution was triggered."
}
