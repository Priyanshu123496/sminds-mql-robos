param(
  [int]$Fast = 20,
  [int]$Slow = 50,
  [double]$Lot = 1.0,
  [string]$FromMonth = "2023-01",
  [string]$ToMonth = "2025-12",
  [int]$Deposit = 25000,
  [string]$Leverage = "1:1000",
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

function Wait-ForReport {
  param([string]$Path,[datetime]$After,[int]$TimeoutSec=360)
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

$startDate = [datetime]::ParseExact($FromMonth + "-01", "yyyy-MM-dd", $null)
$endDate = [datetime]::ParseExact($ToMonth + "-01", "yyyy-MM-dd", $null)

$rows = @()
$cur = $startDate
while($cur -le $endDate) {
  $fromDate = $cur.ToString("yyyy.MM.dd")
  $lastDay = [datetime]::DaysInMonth($cur.Year, $cur.Month)
  $toDate = (Get-Date -Year $cur.Year -Month $cur.Month -Day $lastDay).ToString("yyyy.MM.dd")
  $yyyymm = $cur.ToString("yyyyMM")

  $tag = ("m15_f{0}_s{1}_l{2}_{3}" -f $Fast, $Slow, $Lot, $yyyymm).Replace(".", "p")
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
  $rows += [PSCustomObject]@{
    Month = $cur.ToString("yyyy-MM")
    NetProfit = $net
    ReportFile = $reportPath
  }
  Write-Output ("{0} Net={1}" -f $cur.ToString("yyyy-MM"), $net)

  $cur = $cur.AddMonths(1)
}

$roll = @()
for($i=0; $i -le $rows.Count - 3; $i++) {
  $sum3 = [double]$rows[$i].NetProfit + [double]$rows[$i+1].NetProfit + [double]$rows[$i+2].NetProfit
  $roll += [PSCustomObject]@{
    StartMonth = $rows[$i].Month
    EndMonth = $rows[$i+2].Month
    NetProfit3M = [math]::Round($sum3, 2)
  }
}

$best = $roll | Sort-Object NetProfit3M -Descending | Select-Object -First 1
$hit = $roll | Where-Object { $_.NetProfit3M -gt 24000 } | Select-Object -First 1

$outMonthly = Join-Path $reportDir ("m15_f{0}_s{1}_l{2}_monthly.csv" -f $Fast, $Slow, $Lot).Replace(".", "p")
$outRoll = Join-Path $reportDir ("m15_f{0}_s{1}_l{2}_rolling3m.csv" -f $Fast, $Slow, $Lot).Replace(".", "p")
$rows | Export-Csv -NoTypeInformation -Encoding UTF8 -Path $outMonthly
$roll | Export-Csv -NoTypeInformation -Encoding UTF8 -Path $outRoll

Write-Output ("BEST={0}..{1} Net3M={2}" -f $best.StartMonth, $best.EndMonth, $best.NetProfit3M)
if($null -ne $hit) {
  Write-Output ("TARGET_HIT={0}..{1} Net3M={2}" -f $hit.StartMonth, $hit.EndMonth, $hit.NetProfit3M)
} else {
  Write-Output "TARGET_HIT=NO"
}
Write-Output ("MONTHLY_CSV={0}" -f $outMonthly)
Write-Output ("ROLLING_CSV={0}" -f $outRoll)
