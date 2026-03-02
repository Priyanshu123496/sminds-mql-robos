param(
    [Parameter(Mandatory = $true)]
    [string]$CustomerId,

    [Parameter(Mandatory = $true)]
    [string]$LicenseApiBase
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

$mt5Root = Split-Path -Path $PSScriptRoot -Parent
$eaName = "XAUUSD_EMA20_50_200_Buy_H4"
$sourceEx5 = Join-Path $mt5Root "experts\$eaName.ex5"
$sourceSet = Join-Path $mt5Root "sets\$eaName.set"
$sourceReadme = Join-Path $mt5Root "README_XAUUSD_LICENSING.md"

if (!(Test-Path $sourceEx5)) {
    throw "Missing compiled EA: $sourceEx5"
}
if (!(Test-Path $sourceSet)) {
    throw "Missing set template: $sourceSet"
}
if (!(Test-Path $sourceReadme)) {
    throw "Missing licensing README: $sourceReadme"
}

$releaseRoot = Join-Path $mt5Root "releases\$CustomerId"
$packageRoot = Join-Path $releaseRoot "package"
$zipPath = Join-Path $releaseRoot "$eaName`_$CustomerId.zip"

New-Item -Path $packageRoot -ItemType Directory -Force | Out-Null

Copy-Item -Path $sourceEx5 -Destination (Join-Path $packageRoot "$eaName.ex5") -Force
Copy-Item -Path $sourceReadme -Destination (Join-Path $packageRoot "README_XAUUSD_LICENSING.md") -Force

$setLines = Get-Content -Path $sourceSet
$updated = foreach ($line in $setLines) {
    if ($line -like "InpLicenseId=*") { "InpLicenseId="; continue }
    if ($line -like "InpOtp=*") { "InpOtp="; continue }
    if ($line -like "InpLicenseApiBase=*") { "InpLicenseApiBase=$LicenseApiBase"; continue }
    if ($line -like "InpAllowTradingWithoutLicense=*") { "InpAllowTradingWithoutLicense=false"; continue }
    $line
}

$targetSet = Join-Path $packageRoot "$eaName.set"
Set-Content -Path $targetSet -Value $updated -Encoding ASCII

if (Test-Path $zipPath) {
    Remove-Item -Path $zipPath -Force
}
Compress-Archive -Path (Join-Path $packageRoot "*") -DestinationPath $zipPath -CompressionLevel Optimal

Write-Host "Customer package created:"
Write-Host " - Zip: $zipPath"
Write-Host " - Folder: $packageRoot"
