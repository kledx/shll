param(
    [string]$EnvFile = ".env.demo-agent",
    [switch]$Broadcast
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

if (-not (Test-Path -LiteralPath $EnvFile)) {
    throw "Env file not found: $EnvFile"
}

# Load KEY=VALUE pairs into process env, ignoring comments/blank lines.
Get-Content -LiteralPath $EnvFile | ForEach-Object {
    $line = $_.Trim()
    if (-not $line) { return }
    if ($line.StartsWith("#")) { return }
    $idx = $line.IndexOf("=")
    if ($idx -lt 1) { return }
    $key = $line.Substring(0, $idx).Trim()
    $value = $line.Substring($idx + 1).Trim()
    Set-Item -Path ("env:" + $key) -Value $value
}

if (-not $env:RPC_URL) {
    throw "RPC_URL is missing in env file: $EnvFile"
}

$cmd = @(
    "script",
    "script/ListDemoAgent.s.sol",
    "--rpc-url",
    $env:RPC_URL
)

if ($Broadcast) {
    $cmd += "--broadcast"
}

Write-Host ("Running: forge " + ($cmd -join " "))
& forge @cmd

