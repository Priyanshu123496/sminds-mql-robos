param(
    [string]$RepoRoot = 'C:\SMINDS\projects\sminds-mql-robos',
    [string]$FromMonth = '2023-01',
    [string]$ToMonth = '2025-12',
    [string]$TerminalPath = 'C:\Program Files\MetaTrader 5\terminal64.exe',
    [string]$TerminalDataDir = 'C:\Users\nagas\AppData\Roaming\MetaQuotes\Terminal\D0E8209F77C8CF37AD8BF550E51FF075',
    [int]$Deposit = 25000,
    [string]$Leverage = '1:1000',
    [int]$ProfitInPips = 0,
    [int]$WaitSecondsPerMonth = 900
)

$ErrorActionPreference = 'Stop'

$configDir = Join-Path $RepoRoot 'mt5\config'
$reportDir = Join-Path $RepoRoot 'mt5\reports'

New-Item -ItemType Directory -Force -Path $configDir | Out-Null
New-Item -ItemType Directory -Force -Path $reportDir | Out-Null

function Get-MonthStarts {
    param([string]$Start, [string]$End)

    $startDate = [datetime]::ParseExact("$Start-01", 'yyyy-MM-dd', $null)
    $endDate = [datetime]::ParseExact("$End-01", 'yyyy-MM-dd', $null)

    $months = @()
    $cur = $startDate
    while($cur -le $endDate) {
        $months += $cur
        $cur = $cur.AddMonths(1)
    }
    return $months
}

function Wait-ForReport {
    param(
        [string]$Path,
        [int]$TimeoutSeconds
    )

    $sw = [System.Diagnostics.Stopwatch]::StartNew()
    while($sw.Elapsed.TotalSeconds -lt $TimeoutSeconds) {
        if(Test-Path $Path) {
            return $true
        }
        Start-Sleep -Seconds 1
    }
    return $false
}

function Wait-ForTerminalExit {
    param([int]$TimeoutSeconds = 180)

    $sw = [System.Diagnostics.Stopwatch]::StartNew()
    while($sw.Elapsed.TotalSeconds -lt $TimeoutSeconds) {
        $p = Get-Process terminal64 -ErrorAction SilentlyContinue
        if(-not $p) {
            return $true
        }
        Start-Sleep -Seconds 1
    }
    return $false
}

$months = Get-MonthStarts -Start $FromMonth -End $ToMonth

foreach($ms in $months) {
    $me = $ms.AddMonths(1).AddDays(-1)
    $period = $ms.ToString('yyyy-MM')
    $yyyymm = $ms.ToString('yyyyMM')

    $reportName = "ema50_75_200_buy_xauusd_h1_$yyyymm"
    $iniName = "EMA_small_big_EMA200_Buy_TimeFrame_Symbol_XAUUSD_H1_EMA50_75_$yyyymm.ini"

    $iniPath = Join-Path $configDir $iniName
    $srcReport = Join-Path $TerminalDataDir "$reportName.htm"

    $ini = @"
[Tester]
Expert=EMA_small_big_EMA200_Buy_TimeFrame_Symbol.ex5
Symbol=XAUUSD
Period=H1
Model=4
ExecutionMode=0
Optimization=0
OptimizationCriterion=0
FromDate=$($ms.ToString('yyyy.MM.dd'))
ToDate=$($me.ToString('yyyy.MM.dd'))
ForwardMode=0
Deposit=$Deposit
Currency=USD
Leverage=$Leverage
ProfitInPips=$ProfitInPips
Report=$reportName
ReplaceReport=1
ShutdownTerminal=1
Visual=0
[TesterInputs]
InpLotSize=1.0||1.0||0.100000||100.000000||N
InpFastEmaPeriod=50||50||1||500||N
InpSlowEmaPeriod=75||75||1||500||N
InpStrategyTimeframe=16385||16385||1||43200||N
"@

    Set-Content -Path $iniPath -Value $ini -Encoding ASCII

    Get-Process terminal64 -ErrorAction SilentlyContinue | Stop-Process -Force -ErrorAction SilentlyContinue

    Get-ChildItem -Path $TerminalDataDir -Filter "$reportName*" -ErrorAction SilentlyContinue | Remove-Item -Force -ErrorAction SilentlyContinue
    Get-ChildItem -Path $reportDir -Filter "$reportName*" -ErrorAction SilentlyContinue | Remove-Item -Force -ErrorAction SilentlyContinue

    Write-Host "[$period] Starting tester..."
    & $TerminalPath /portable "/config:$iniPath"

    $ok = Wait-ForReport -Path $srcReport -TimeoutSeconds $WaitSecondsPerMonth
    if($ok) {
        Get-ChildItem -Path $TerminalDataDir -Filter "$reportName*" | ForEach-Object {
            Copy-Item -LiteralPath $_.FullName -Destination (Join-Path $reportDir $_.Name) -Force
        }
        Write-Host "[$period] Report copied."
    }
    else {
        Write-Warning "[$period] Report not found within timeout."
    }

    if(-not (Wait-ForTerminalExit -TimeoutSeconds 240)) {
        Write-Warning "[$period] terminal64.exe still running after timeout; forcing stop."
        Get-Process terminal64 -ErrorAction SilentlyContinue | Stop-Process -Force -ErrorAction SilentlyContinue
    }
}

Write-Host 'Backtest batch finished.'
