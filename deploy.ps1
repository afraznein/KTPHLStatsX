# KTP HLStatsX Deployment Script
# Deploys KTP HLStatsX files to the data server

$ErrorActionPreference = "Stop"

Write-Host "========================================"
Write-Host "KTP HLStatsX Deployment"
Write-Host "========================================"
Write-Host ""

# Configuration
$SourceDir = $PSScriptRoot
$StagingDest = "N:\Nein_\KTP DoD Server\hlstatsx"

# Ensure staging directory exists
if (-not (Test-Path $StagingDest)) {
    Write-Host "Creating staging directory: $StagingDest"
    New-Item -ItemType Directory -Path $StagingDest -Force | Out-Null
}

if (-not (Test-Path "$StagingDest\scripts")) {
    New-Item -ItemType Directory -Path "$StagingDest\scripts" -Force | Out-Null
}

if (-not (Test-Path "$StagingDest\sql")) {
    New-Item -ItemType Directory -Path "$StagingDest\sql" -Force | Out-Null
}

Write-Host "Source: $SourceDir"
Write-Host "Destination: $StagingDest"
Write-Host ""

# Copy scripts
Write-Host "Deploying Perl scripts..."
$scripts = @(
    "hlstats.pl",
    "HLstats.plib",
    "HLstats_EventHandlers.plib"
)

foreach ($script in $scripts) {
    $src = "$SourceDir\scripts\$script"
    $dst = "$StagingDest\scripts\$script"
    if (Test-Path $src) {
        Copy-Item -Path $src -Destination $dst -Force
        Write-Host "  Deployed: $script"
    } else {
        Write-Host "  WARNING: $script not found"
    }
}

# Copy SQL files
Write-Host ""
Write-Host "Deploying SQL schema..."
if (Test-Path "$SourceDir\sql") {
    $sqlFiles = Get-ChildItem -Path "$SourceDir\sql" -Filter "*.sql"
    foreach ($sqlFile in $sqlFiles) {
        Copy-Item -Path $sqlFile.FullName -Destination "$StagingDest\sql\$($sqlFile.Name)" -Force
        Write-Host "  Deployed: $($sqlFile.Name)"
    }
}

# Copy documentation
Write-Host ""
Write-Host "Deploying documentation..."
$docs = @("README.md", "CHANGELOG.md", "VERSION")
foreach ($doc in $docs) {
    $src = "$SourceDir\$doc"
    if (Test-Path $src) {
        Copy-Item -Path $src -Destination "$StagingDest\$doc" -Force
        Write-Host "  Deployed: $doc"
    }
}

# Show version
$version = Get-Content "$SourceDir\VERSION" -Raw
Write-Host ""
Write-Host "========================================"
Write-Host "Deployment Complete!"
Write-Host "Version: $($version.Trim())"
Write-Host "========================================"
Write-Host ""
Write-Host "Next steps:"
Write-Host "  1. Run the SQL migration: $StagingDest\sql\ktp_schema.sql"
Write-Host "  2. Restart the hlstats daemon"
