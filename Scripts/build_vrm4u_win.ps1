#!/usr/bin/env pwsh
# Windows companion to build_vrm4u_mac.sh. Same flag surface, same workflow,
# minus the assimp build (VRM4U ships ThirdParty\assimp\lib\x64\Release\
# assimp-vc141-mt.lib and the matching .dll, so no CMake step is needed).
#
# Usage:
#   .\Scripts\build_vrm4u_win.ps1                  # info only
#   .\Scripts\build_vrm4u_win.ps1 -Deploy          # mirror source into engine
#   .\Scripts\build_vrm4u_win.ps1 -Precompile      # also build DLLs via UBT
#   .\Scripts\build_vrm4u_win.ps1 -Dev             # also ship UHT headers
#   .\Scripts\build_vrm4u_win.ps1 -Force           # wipe PrecompileHost first
#   .\Scripts\build_vrm4u_win.ps1 -Engine "D:\UE_5.7"
#
# Flags can be combined. Default engine root is C:\Program Files\Epic Games\UE_5.7.
# -Dev implies -Precompile implies -Deploy. -Precompile spins up a stub
# HostProject containing VRM4U as a project plugin and runs UBT against it,
# bypassing the installed-engine restriction that blocks recompiling
# engine/Marketplace plugins. -Dev additionally ships the UHT-generated
# *.generated.h headers so downstream C++ consumers (e.g. Monolith with
# bHasVRM4U-gated modules) can compile against VRM4U types.

[CmdletBinding()]
param(
    [switch]$Deploy,
    [switch]$Precompile,
    [switch]$Dev,
    [switch]$Force,
    [string]$Engine = "C:\Program Files\Epic Games\UE_5.7"
)

$ErrorActionPreference = 'Stop'

# ─── flag implications ──────────────────────────────────────────────────────
if ($Dev)        { $Precompile = $true }
if ($Precompile) { $Deploy     = $true }

# ─── paths ──────────────────────────────────────────────────────────────────
$ScriptDir      = Split-Path -Parent $MyInvocation.MyCommand.Path
$ProjectRoot    = (Resolve-Path (Join-Path $ScriptDir '..')).Path
$UPlugin        = Join-Path $ProjectRoot 'VRM4U.uplugin'

if (-not (Test-Path $UPlugin)) {
    throw "VRM4U.uplugin not found at $UPlugin — this script must live in <VRM4U>\Scripts\"
}

# VRM4ULoader.Build.cs (Win64 path, bDebug=false) link-depends on the release
# assimp lib + delay-loads the matching DLL. Both ship in the repo — fail fast
# with a clear message instead of waiting 5+ min for UBT to hit a link error.
$AssimpLib = Join-Path $ProjectRoot 'ThirdParty\assimp\lib\x64\Release\assimp-vc141-mt.lib'
$AssimpDll = Join-Path $ProjectRoot 'ThirdParty\assimp\bin\x64\assimp-vc141-mt.dll'
foreach ($req in @($AssimpLib, $AssimpDll)) {
    if (-not (Test-Path $req)) {
        throw "missing third-party artifact: $req`n       repo not fully cloned? (LFS-tracked file may be a pointer)"
    }
}

$WorkDir        = Join-Path $ProjectRoot 'Intermediate\VRM4UWinBuild'
$PrecompileHost = Join-Path $WorkDir     'PrecompileHost'
$DeployDir      = Join-Path $Engine      'Engine\Plugins\Marketplace\VRM4U'
$UbtBuildBat    = Join-Path $Engine      'Engine\Build\BatchFiles\Build.bat'

Write-Host "→ project root:    $ProjectRoot"
Write-Host "→ engine root:     $Engine"
if ($Deploy)     { Write-Host "→ deploy target:   $DeployDir" }
if ($Precompile) { Write-Host "→ precompile via:  $UbtBuildBat" }
if ($Dev)        { Write-Host "→ dev headers to:  $DeployDir\Intermediate\Build\Win64\..." }

if (-not ($Deploy -or $Precompile -or $Dev)) {
    Write-Host ""
    Write-Host "(no action flags passed — try -Deploy, -Precompile, or -Dev. -h for help.)"
    exit 0
}

# robocopy returns 0-7 on success, 8+ on failure. Wrap to fold into a normal
# pipeline. Quiet flags suppress per-file noise.
function Invoke-Robocopy {
    param(
        [Parameter(Mandatory)] [string] $From,
        [Parameter(Mandatory)] [string] $To,
        [string[]] $ExcludeDirs = @(),
        [string]   $Label = 'robocopy'
    )
    $args = @($From, $To, '/MIR', '/NFL', '/NDL', '/NJH', '/NJS', '/NP')
    if ($ExcludeDirs.Count -gt 0) {
        $args += '/XD'
        $args += $ExcludeDirs
    }
    & robocopy @args
    if ($LASTEXITCODE -ge 8) { throw "$Label failed (robocopy exit $LASTEXITCODE)" }
    # Reset so callers' `if ($LASTEXITCODE -ne 0)` checks don't see a stale "success-with-copies" code.
    $global:LASTEXITCODE = 0
}

$StagingExcludes = @('.git', 'Intermediate', 'Saved', 'Binaries', 'DerivedDataCache', '.idea', '.vs')

# ─── deploy ─────────────────────────────────────────────────────────────────
if ($Deploy) {
    if (-not (Test-Path (Join-Path $Engine 'Engine'))) {
        throw "engine root not found at $Engine — override with -Engine <path>"
    }
    Write-Host "→ deploying source to: $DeployDir"
    New-Item -ItemType Directory -Force -Path $DeployDir | Out-Null
    Invoke-Robocopy -From $ProjectRoot -To $DeployDir -ExcludeDirs $StagingExcludes -Label 'deploy'
    Write-Host "→ deployed."
}

# ─── precompile dylibs via UBT ──────────────────────────────────────────────
# Engine plugins cannot be rebuilt from the editor at runtime ("Engine modules
# cannot be compiled at runtime. Please build through your IDE."). Pre-build
# a stub HostProject's editor target so UBT produces UnrealEditor-VRM4U*.dll
# under Engine\Plugins\Marketplace\VRM4U\Binaries\Win64.
if ($Precompile) {
    if (-not (Test-Path $UbtBuildBat)) { throw "UBT Build.bat missing at $UbtBuildBat" }

    if ($Force -and (Test-Path $PrecompileHost)) {
        Write-Host "→ -Force: wiping $PrecompileHost"
        Remove-Item -Recurse -Force $PrecompileHost
    }

    Write-Host "→ generating stub HostProject at $PrecompileHost"
    New-Item -ItemType Directory -Force -Path "$PrecompileHost\Source\HostProject" | Out-Null
    New-Item -ItemType Directory -Force -Path "$PrecompileHost\Plugins"             | Out-Null

    $uprojectJson = @'
{
  "FileVersion": 3,
  "EngineAssociation": "",
  "Category": "",
  "Description": "",
  "Modules": [
    { "Name": "HostProject", "Type": "Runtime", "LoadingPhase": "Default" }
  ],
  "Plugins": [
    { "Name": "VRM4U", "Enabled": true }
  ]
}
'@
    Set-Content -Path (Join-Path $PrecompileHost 'HostProject.uproject') -Value $uprojectJson -NoNewline

    $editorTargetCs = @'
using UnrealBuildTool;
public class HostProjectEditorTarget : TargetRules {
  public HostProjectEditorTarget(TargetInfo Target) : base(Target) {
    DefaultBuildSettings = BuildSettingsVersion.Latest;
    IncludeOrderVersion = EngineIncludeOrderVersion.Latest;
    Type = TargetType.Editor;
    ExtraModuleNames.Add("HostProject");
  }
}
'@
    Set-Content -Path (Join-Path $PrecompileHost 'Source\HostProjectEditor.Target.cs') -Value $editorTargetCs -NoNewline

    $moduleBuildCs = @'
using UnrealBuildTool;
public class HostProject : ModuleRules {
  public HostProject(ReadOnlyTargetRules Target) : base(Target) {
    PCHUsage = PCHUsageMode.UseExplicitOrSharedPCHs;
    PrivateDependencyModuleNames.Add("Core");
  }
}
'@
    Set-Content -Path (Join-Path $PrecompileHost 'Source\HostProject\HostProject.Build.cs') -Value $moduleBuildCs -NoNewline
    Set-Content -Path (Join-Path $PrecompileHost 'Source\HostProject\HostProject.cpp')      -Value "// stub`n" -NoNewline

    # Stage VRM4U as a project-level plugin inside the HostProject. UBT will
    # happily compile project plugins even against an installed/Rocket engine
    # where engine/Marketplace plugins are treated as immutable precompiled.
    # Monolith's Marketplace→VRM4U hierarchy validation never fires because
    # Monolith isn't enabled in the HostProject.
    Write-Host "→ staging VRM4U source into HostProject\Plugins\VRM4U"
    $StagedVrm4u = Join-Path $PrecompileHost 'Plugins\VRM4U'
    New-Item -ItemType Directory -Force -Path $StagedVrm4u | Out-Null
    Invoke-Robocopy -From $ProjectRoot -To $StagedVrm4u -ExcludeDirs $StagingExcludes -Label 'stage'

    Write-Host "→ invoking UBT (this compiles all 8 VRM4U modules — ~5-10 min)"
    & $UbtBuildBat HostProjectEditor Win64 Development `
        "-Project=$PrecompileHost\HostProject.uproject" -waitmutex
    if ($LASTEXITCODE -ne 0) { throw "UBT failed (exit $LASTEXITCODE)" }

    $CompiledBin = Join-Path $StagedVrm4u 'Binaries\Win64'
    $dlls = @(Get-ChildItem -Path $CompiledBin -Filter *.dll -ErrorAction SilentlyContinue)
    if ($dlls.Count -eq 0) {
        throw "UBT finished but no DLLs found at $CompiledBin"
    }

    Write-Host "→ copying compiled DLLs into engine Marketplace install"
    New-Item -ItemType Directory -Force -Path "$DeployDir\Binaries\Win64" | Out-Null
    Invoke-Robocopy -From $CompiledBin -To "$DeployDir\Binaries\Win64" -Label 'install-dlls'
    Write-Host "→ precompile done:"
    Get-ChildItem "$DeployDir\Binaries\Win64" -Filter *.dll | ForEach-Object { Write-Host "    $($_.Name)" }
}

# ─── dev: ship UHT-generated headers for downstream C++ consumers ───────────
# UBT writes *.generated.h into the precompile host's Inc/ tree as a side
# effect of building the editor target. Downstream plugins (e.g. Monolith)
# need them at compile time. UE 5.x added an x64\ arch sub-dir under
# Intermediate\Build\Win64; older layouts don't have it. Probe both.
$DstInc = $null
if ($Dev) {
    $SrcInc = $null
    foreach ($cand in @(
        (Join-Path $PrecompileHost 'Plugins\VRM4U\Intermediate\Build\Win64\x64\UnrealEditor\Inc'),
        (Join-Path $PrecompileHost 'Plugins\VRM4U\Intermediate\Build\Win64\UnrealEditor\Inc')
    )) {
        if (Test-Path $cand) { $SrcInc = $cand; break }
    }
    if (-not $SrcInc) {
        throw "no Inc/ tree found under PrecompileHost — was -Precompile actually run?"
    }

    # Preserve the same relative path layout (Intermediate\Build\...) inside
    # the deploy so UBT autodetects the headers via its standard plugin probe.
    $rel    = $SrcInc.Substring($SrcInc.IndexOf('Intermediate\Build'))
    $DstInc = Join-Path $DeployDir $rel
    Write-Host "→ shipping UHT-generated headers to: $DstInc"
    New-Item -ItemType Directory -Force -Path $DstInc | Out-Null
    Invoke-Robocopy -From $SrcInc -To $DstInc -Label 'install-headers'
    $hdrCount = @(Get-ChildItem $DstInc -Recurse -Filter *.generated.h -ErrorAction SilentlyContinue).Count
    Write-Host "→ dev headers installed ($hdrCount *.generated.h files)"
}

Write-Host ""
Write-Host "Done."
if ($Deploy)     { Write-Host "  deployed    : $DeployDir" }
if ($Precompile) { Write-Host "  dlls        : $DeployDir\Binaries\Win64" }
if ($Dev)        { Write-Host "  dev headers : $DstInc" }
