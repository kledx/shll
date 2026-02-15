param(
    [string]$EnvFile = ".env.update-pack",
    [switch]$Broadcast
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

$projectRoot = Split-Path -Parent $PSScriptRoot
$envCandidates = @(
    $EnvFile,
    (Join-Path $projectRoot $EnvFile)
)

$resolvedEnvFile = $null
foreach ($candidate in $envCandidates) {
    if (Test-Path -LiteralPath $candidate) {
        $resolvedEnvFile = (Resolve-Path -LiteralPath $candidate).Path
        break
    }
}

if (-not $resolvedEnvFile) {
    throw "Env file not found: $EnvFile"
}

# Load KEY=VALUE pairs into process env, ignoring comments/blank lines.
Get-Content -LiteralPath $resolvedEnvFile | ForEach-Object {
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
    throw "RPC_URL is missing in env file: $resolvedEnvFile"
}

$cmd = @(
    "script",
    "script/UpdateAgentPack.s.sol:UpdateAgentPack",
    "--rpc-url",
    $env:RPC_URL
)

if ($Broadcast) {
    $cmd += "--broadcast"
}

Write-Host "Project root: $projectRoot"
Write-Host "Env file: $resolvedEnvFile"
Write-Host ("Running: forge " + ($cmd -join " "))
Push-Location $projectRoot
try {
    & forge @cmd
} finally {
    Pop-Location
}
