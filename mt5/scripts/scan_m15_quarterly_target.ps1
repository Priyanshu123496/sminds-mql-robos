param(
  [int]$Deposit = 25000,
  [string]$Leverage = "1:1000",
  [double]$TargetQuarterNet = 21000.0,
  [string]$RepoRoot = "C:\SMINDS\projects\sminds-mql-robos",
  [string]$TerminalPath = "C:\Program Files\MetaTrader 5\terminal64.exe",
  [string]$TerminalDataDir = "C:\Users\nagas\AppData\Roaming\MetaQuotes\Terminal\D0E8209F77C8CF37AD8BF550E51FF075"
)

$ErrorActionPreference = "Stop"

$configDir = Join-Path $RepoRoot "mt5\config"
$reportDir = Join-Path $RepoRoot "mt5\reports"
$expert = "EMA_small_big_EMA200_Buy_TimeFrame_Symbol.ex5"
$ex5Repo = Join-Path $RepoRoot ("mt5\experts\" + $expert)
$ex5Terminal = Join-Path $TerminalDataDir ("MQL5\Experts\" + $expert)

New-Item -ItemType Directory -Force -Path $configDir,$reportDir,(Split-Path $ex5Terminal -Parent) | Out-Null
Copy-Item -LiteralPath $ex5Repo -Destination $ex5Terminal -Force

$quarters = @()
foreach($y in 2023..2025) {
  $quarters += [PSCustomObject]@{Year=$y;Q='Q1';From="{0}.01.01" -f $y;To="{0}.03.31" -f $y;Label="{0}Q1" -f $y}
  $quarters += [PSCustomObject]@{Year=$y;Q='Q2';From="{0}.04.01" -f $y;To="{0}.06.30" -f $y;Label="{0}Q2" -f $y}
  $quarters += [PSCustomObject]@{Year=$y;Q='Q3';From="{0}.07.01" -f $y;To="{0}.09.30" -f $y;Label="{0}Q3" -f $y}
  $quarters += [PSCustomObject]@{Year=$y;Q='Q4';From="{0}.10.01" -f $y;To="{0}.12.31" -f $y;Label="{0}Q4" -f $y}
}

function Wait-ForReport {
  param([string]$Path,[datetime]$After,[int]$TimeoutSec=420)
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

function Parse-NetProfit {
  param([string]$ReportPath)
  if(!(Test-Path $ReportPath)) { return $null }
  $html = Get-Content -Raw -Path $ReportPath
  $m = [regex]::Match($html, "Total Net Profit:\\s*</td>\\s*<td[^>]*>\\s*<b>(.*?)</b>", "IgnoreCase,Singleline")
  if(!$m.Success) { return $null }
  $raw = $m.Groups[1].Value
  $num = ($raw -replace "[^0-9\.\-]", "")
  if([string]::IsNullOrWhiteSpace($num)) { return 0.0 }
  return [double]$num
}

function Run-Candidate {
  param([int]$Fast,[int]$Slow,[double]$Lot)

  $qrows = @()
  $allOk = $true
  foreach($q in $quarters) {
    $tag = ("m15scan_f{0}_s{1}_l{2}_{3}" -f $Fast,$Slow,$Lot,$q.Label).Replace(".","p")
    $iniPath = Join-Path $configDir ($tag + ".ini")
    $terminalReport = Join-Path $TerminalDataDir ($tag + ".htm")
    $reportPath = Join-Path $reportDir ($tag + ".htm")

    $ini = @"
[Tester]
Expert=$expert
Symbol=XAUUSD
Period=M15
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
InpLotSize=$Lot||$Lot||0.100000||100.000000||N
InpFastEmaPeriod=$Fast||$Fast||1||500||N
InpSlowEmaPeriod=$Slow||$Slow||1||500||N
InpStrategyTimeframe=15||15||1||43200||N
"@
    Set-Content -Path $iniPath -Value $ini -Encoding ASCII

    Remove-Item -Force -ErrorAction SilentlyContinue $terminalReport,$reportPath
    $launch = Get-Date
    & $TerminalPath "/config:$iniPath" | Out-Null
    $ok = Wait-ForReport -Path $terminalReport -After $launch -TimeoutSec 420
    if($ok) {
      Copy-Item -LiteralPath $terminalReport -Destination $reportPath -Force
    }

    $net = Parse-NetProfit -ReportPath $reportPath
    if($null -eq $net) { $net = -999999.0 }
    $qrows += [PSCustomObject]@{Quarter=$q.Label;NetQuarter=$net;ReportFile=$reportPath}

    if($net -le $TargetQuarterNet) {
      $allOk = $false
      break
    }
  }

  $minQ = ($qrows | Measure-Object -Property NetQuarter -Minimum).Minimum
  $avgQ = ($qrows | Measure-Object -Property NetQuarter -Average).Average
  [PSCustomObject]@{
    FastEma = $Fast
    SlowEma = $Slow
    LotSize = $Lot
    QuartersTested = $qrows.Count
    MinQuarterNet = [math]::Round($minQ,2)
    AvgQuarterNet = [math]::Round($avgQ,2)
    MeetsAll12 = ($allOk -and $qrows.Count -eq 12)
  }
}

# staged grid (kept bounded for runtime)
$fastList = @(9,12,15,20,25,30,34,40,50,55)
$slowList = @(30,40,50,60,75,89,100,120,144,150)
$lotList = @(1.0,1.5,2.0,3.0,4.0,5.0)

$results = @()
$pass = @()

foreach($f in $fastList) {
  foreach($s in $slowList) {
    if($f -ge $s) { continue }
    foreach($l in $lotList) {
      $r = Run-Candidate -Fast $f -Slow $s -Lot $l
      $results += $r
      Write-Output ("f={0} s={1} l={2} tested={3} minQ={4} avgQ={5} pass={6}" -f $f,$s,$l,$r.QuartersTested,$r.MinQuarterNet,$r.AvgQuarterNet,$r.MeetsAll12)
      if($r.MeetsAll12) { $pass += $r }
    }
  }
}

$resultsCsv = Join-Path $reportDir "m15_quarterly_target_scan_results.csv"
$passCsv = Join-Path $reportDir "m15_quarterly_target_scan_pass.csv"
$results | Sort-Object MinQuarterNet -Descending | Export-Csv -NoTypeInformation -Encoding UTF8 -Path $resultsCsv
$pass | Sort-Object MinQuarterNet -Descending | Export-Csv -NoTypeInformation -Encoding UTF8 -Path $passCsv

$best = $results | Sort-Object MinQuarterNet -Descending | Select-Object -First 10
Write-Output "TOP10_BY_MIN_QUARTER"
$best | Format-Table -AutoSize | Out-String | Write-Output
Write-Output ("RESULTS_CSV=" + $resultsCsv)
Write-Output ("PASS_CSV=" + $passCsv)
