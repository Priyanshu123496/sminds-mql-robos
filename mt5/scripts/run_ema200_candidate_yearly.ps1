param(
    [Parameter(Mandatory = $true)][string]$Label,
    [Parameter(Mandatory = $true)][double]$LotSize,
    [Parameter(Mandatory = $true)][int]$FastEma,
    [Parameter(Mandatory = $true)][int]$SlowEma,
    [Parameter(Mandatory = $true)][int]$TimeframeCode,
    [string]$TesterPeriod = "H1",
    [string]$Symbol = "XAUUSD",
    [int]$Deposit = 25000,
    [string]$Leverage = "1:1000",
    [string]$RepoRoot = "C:\SMINDS\projects\sminds-mql-robos",
    [string]$TerminalPath = "C:\Program Files\MetaTrader 5\terminal64.exe",
    [string]$TerminalDataDir = "C:\Users\nagas\AppData\Roaming\MetaQuotes\Terminal\D0E8209F77C8CF37AD8BF550E51FF075",
    [int]$WaitTimeoutSec = 240
)

$ErrorActionPreference = "Stop"

$configDir = Join-Path $RepoRoot "mt5\config"
$reportDir = Join-Path $RepoRoot "mt5\reports"
$ex5RepoPath = Join-Path $RepoRoot "mt5\experts\EMA_small_big_EMA200_Buy_TimeFrame_Symbol.ex5"
$ex5TerminalPath = Join-Path $TerminalDataDir "MQL5\Experts\EMA_small_big_EMA200_Buy_TimeFrame_Symbol.ex5"

New-Item -ItemType Directory -Force -Path $configDir | Out-Null
New-Item -ItemType Directory -Force -Path $reportDir | Out-Null
New-Item -ItemType Directory -Force -Path (Split-Path $ex5TerminalPath -Parent) | Out-Null
Copy-Item -LiteralPath $ex5RepoPath -Destination $ex5TerminalPath -Force

function Wait-ForReport {
    param(
        [string]$Path,
        [datetime]$After,
        [int]$TimeoutSec
    )
    $start = Get-Date
    while(((Get-Date) - $start).TotalSeconds -lt $TimeoutSec) {
        if(Test-Path $Path) {
            $item = Get-Item $Path
            if($item.LastWriteTime -ge $After) {
                return $true
            }
        }
        Start-Sleep -Seconds 1
    }
    return $false
}

function Parse-ReportMetric {
    param(
        [string]$Html,
        [string]$Label
    )
    $pattern = [regex]::Escape($Label) + ".*?<b>(.*?)</b>"
    $m = [regex]::Match($Html, $pattern, "IgnoreCase,Singleline")
    if($m.Success) { return $m.Groups[1].Value.Trim() }
    return ""
}

function To-Number {
    param([string]$Raw)
    if([string]::IsNullOrWhiteSpace($Raw)) { return 0.0 }
    $n = ($Raw -replace "[^0-9\.\-]", "")
    if([string]::IsNullOrWhiteSpace($n)) { return 0.0 }
    return [double]$n
}

$years = @(2023, 2024, 2025)
$results = @()

foreach($year in $years) {
    $fromDate = "{0}.01.01" -f $year
    $toDate = "{0}.12.31" -f $year
    $tag = "{0}_{1}" -f $Label, $year
    $iniPath = Join-Path $configDir ("{0}.ini" -f $tag)
    $terminalReport = Join-Path $TerminalDataDir ("{0}.htm" -f $tag)

    $ini = @"
[Tester]
Expert=EMA_small_big_EMA200_Buy_TimeFrame_Symbol.ex5
Symbol=$Symbol
Period=$TesterPeriod
Model=4
ExecutionMode=0
Optimization=0
OptimizationCriterion=0
FromDate=$fromDate
ToDate=$toDate
ForwardMode=0
Deposit=$Deposit
Currency=USD
Leverage=$Leverage
ProfitInPips=0
Report=$tag
ReplaceReport=1
ShutdownTerminal=1
Visual=0
[TesterInputs]
InpLotSize=$LotSize||$LotSize||0.100000||100.000000||N
InpFastEmaPeriod=$FastEma||$FastEma||1||500||N
InpSlowEmaPeriod=$SlowEma||$SlowEma||1||500||N
InpStrategyTimeframe=$TimeframeCode||$TimeframeCode||1||43200||N
"@
    Set-Content -Path $iniPath -Value $ini -Encoding ASCII

    Get-Process terminal64 -ErrorAction SilentlyContinue | Stop-Process -Force -ErrorAction SilentlyContinue
    Get-ChildItem -Path $TerminalDataDir -Filter "$tag*" -ErrorAction SilentlyContinue | Remove-Item -Force -ErrorAction SilentlyContinue
    Get-ChildItem -Path $reportDir -Filter "$tag*" -ErrorAction SilentlyContinue | Remove-Item -Force -ErrorAction SilentlyContinue

    $launchTime = Get-Date
    & $TerminalPath "/config:$iniPath" | Out-Null
    $found = Wait-ForReport -Path $terminalReport -After $launchTime -TimeoutSec $WaitTimeoutSec

    if(-not $found) {
        Write-Output "$Label $year Net=NA (report timeout)"
        $results += [PSCustomObject]@{
            Label = $Label
            Year = $year
            NetProfit = $null
            GrossProfit = $null
            GrossLoss = $null
        }
        continue
    }

    Get-ChildItem -Path $TerminalDataDir -Filter "$tag*" | ForEach-Object {
        Copy-Item -LiteralPath $_.FullName -Destination (Join-Path $reportDir $_.Name) -Force
    }

    $html = Get-Content $terminalReport -Raw
    $net = To-Number (Parse-ReportMetric -Html $html -Label "Total Net Profit:")
    $gp = To-Number (Parse-ReportMetric -Html $html -Label "Gross Profit:")
    $gl = To-Number (Parse-ReportMetric -Html $html -Label "Gross Loss:")

    Write-Output ("{0} {1} Net={2:N2} GP={3:N2} GL={4:N2}" -f $Label, $year, $net, $gp, $gl)
    $results += [PSCustomObject]@{
        Label = $Label
        Year = $year
        NetProfit = $net
        GrossProfit = $gp
        GrossLoss = $gl
    }
}

$valid = $results | Where-Object { $_.NetProfit -ne $null }
if($valid.Count -eq 3) {
    $minYear = ($valid | Measure-Object -Property NetProfit -Minimum).Minimum
    $sumAll = ($valid | Measure-Object -Property NetProfit -Sum).Sum
    Write-Output ("{0} SUMMARY MinYearNet={1:N2} Total3YNet={2:N2}" -f $Label, $minYear, $sumAll)
}
