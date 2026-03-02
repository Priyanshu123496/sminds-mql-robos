param(
    [Parameter(Mandatory = $true)][string]$Label,
    [Parameter(Mandatory = $true)][double]$LotSize,
    [Parameter(Mandatory = $true)][int]$FastEma,
    [Parameter(Mandatory = $true)][int]$SlowEma,
    [Parameter(Mandatory = $true)][int]$TimeframeCode,
    [string]$TesterPeriod = "M15",
    [string]$Symbol = "XAUUSD",
    [int]$Deposit = 25000,
    [string]$Leverage = "1:1000",
    [double]$TargetQuarterNet = 21000,
    [double]$StopIfQuarterNetLe = -1.0e300,
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

New-Item -ItemType Directory -Force -Path $configDir,$reportDir,(Split-Path $ex5TerminalPath -Parent) | Out-Null
Copy-Item -LiteralPath $ex5RepoPath -Destination $ex5TerminalPath -Force

function Wait-ForReport {
    param([string]$Path,[datetime]$After,[int]$TimeoutSec)
    $start = Get-Date
    while(((Get-Date) - $start).TotalSeconds -lt $TimeoutSec) {
        if(Test-Path $Path) {
            $it = Get-Item $Path
            if($it.LastWriteTime -ge $After) { return $true }
        }
        Start-Sleep -Seconds 1
    }
    return $false
}

function Parse-ReportMetric {
    param([string]$Html,[string]$Label)
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

$quarters = @(
    @{ Name='2023Q1'; From='2023.01.01'; To='2023.03.31' },
    @{ Name='2023Q2'; From='2023.04.01'; To='2023.06.30' },
    @{ Name='2023Q3'; From='2023.07.01'; To='2023.09.30' },
    @{ Name='2023Q4'; From='2023.10.01'; To='2023.12.31' },
    @{ Name='2024Q1'; From='2024.01.01'; To='2024.03.31' },
    @{ Name='2024Q2'; From='2024.04.01'; To='2024.06.30' },
    @{ Name='2024Q3'; From='2024.07.01'; To='2024.09.30' },
    @{ Name='2024Q4'; From='2024.10.01'; To='2024.12.31' },
    @{ Name='2025Q1'; From='2025.01.01'; To='2025.03.31' },
    @{ Name='2025Q2'; From='2025.04.01'; To='2025.06.30' },
    @{ Name='2025Q3'; From='2025.07.01'; To='2025.09.30' },
    @{ Name='2025Q4'; From='2025.10.01'; To='2025.12.31' }
)

$results = @()

foreach($q in $quarters) {
    $tag = "{0}_{1}" -f $Label, $q.Name
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
FromDate=$($q.From)
ToDate=$($q.To)
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
        Write-Output "$Label $($q.Name) Net=NA (report timeout)"
        $results += [PSCustomObject]@{Quarter=$q.Name;NetProfit=$null;GrossProfit=$null;GrossLoss=$null}
        continue
    }

    Get-ChildItem -Path $TerminalDataDir -Filter "$tag*" | ForEach-Object {
        Copy-Item -LiteralPath $_.FullName -Destination (Join-Path $reportDir $_.Name) -Force
    }

    $html = Get-Content $terminalReport -Raw
    $net = To-Number (Parse-ReportMetric -Html $html -Label "Total Net Profit:")
    $gp = To-Number (Parse-ReportMetric -Html $html -Label "Gross Profit:")
    $gl = To-Number (Parse-ReportMetric -Html $html -Label "Gross Loss:")

    Write-Output ("{0} {1} Net={2:N2} GP={3:N2} GL={4:N2}" -f $Label, $q.Name, $net, $gp, $gl)
    $results += [PSCustomObject]@{Quarter=$q.Name;NetProfit=$net;GrossProfit=$gp;GrossLoss=$gl}

    if($net -le $StopIfQuarterNetLe) {
        Write-Output ("{0} EARLY_STOP Quarter={1} Net={2:N2} <= StopIfQuarterNetLe={3:N2}" -f $Label, $q.Name, $net, $StopIfQuarterNetLe)
        break
    }
}

$valid = $results | Where-Object { $_.NetProfit -ne $null }
if($valid.Count -gt 0) {
    $minQ = ($valid | Measure-Object -Property NetProfit -Minimum).Minimum
    $avgQ = ($valid | Measure-Object -Property NetProfit -Average).Average
    $passAll = ($valid.Count -eq 12 -and $minQ -gt $TargetQuarterNet)
    Write-Output ("{0} SUMMARY MinQuarterNet={1:N2} AvgQuarterNet={2:N2} PassAll12={3}" -f $Label, $minQ, $avgQ, $passAll)
}
