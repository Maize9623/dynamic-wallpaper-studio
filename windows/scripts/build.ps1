[CmdletBinding()]
param(
    [ValidateSet("Debug", "Release")]
    [string]$Configuration = "Release",

    [string]$RuntimeIdentifier = "win-x64",

    [string]$OutputDirectory = "",

    [switch]$SkipDependencyDownload
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

$projectRoot = [System.IO.Path]::GetFullPath((Join-Path $PSScriptRoot ".."))
$projectFile = Join-Path $projectRoot "DynamicWallpaperStudio.Windows.csproj"

if ([string]::IsNullOrWhiteSpace($OutputDirectory)) {
    $OutputDirectory = Join-Path $projectRoot "artifacts\DynamicWallpaperStudio-Windows-x64"
}
$publishRoot = [System.IO.Path]::GetFullPath($OutputDirectory)

if (-not (Get-Command dotnet -ErrorAction SilentlyContinue)) {
    throw ".NET 10 SDK was not found. Install it from https://dotnet.microsoft.com/download/dotnet/10.0"
}

if (-not $SkipDependencyDownload) {
    & (Join-Path $PSScriptRoot "fetch-dependencies.ps1")
    if ($LASTEXITCODE -ne 0) {
        throw "Dependency download failed with exit code $LASTEXITCODE."
    }
}

$requiredTools = @("mpv.exe", "vulkan-1.dll", "ffmpeg.exe", "ffprobe.exe")
$missingTools = @($requiredTools | Where-Object {
    -not (Test-Path -LiteralPath (Join-Path $projectRoot ("tools\" + $_)) -PathType Leaf)
})
if ($missingTools.Count -gt 0) {
    throw "Missing runtime dependencies: $($missingTools -join ', '). Run scripts\fetch-dependencies.ps1 first."
}

if ((Test-Path -LiteralPath $publishRoot) -and
    @(Get-ChildItem -LiteralPath $publishRoot -Force).Count -gt 0) {
    throw "Output directory is not empty: $publishRoot. Choose a new -OutputDirectory or remove the old build explicitly."
}

[System.IO.Directory]::CreateDirectory($publishRoot) | Out-Null

Write-Host "Publishing Dynamic Wallpaper Studio to $publishRoot"
& dotnet publish $projectFile `
    --configuration $Configuration `
    --runtime $RuntimeIdentifier `
    --self-contained true `
    --output $publishRoot

if ($LASTEXITCODE -ne 0) {
    throw "dotnet publish failed with exit code $LASTEXITCODE."
}

Write-Host "Build complete: $publishRoot"
