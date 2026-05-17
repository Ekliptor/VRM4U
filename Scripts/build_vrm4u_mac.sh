#!/usr/bin/env bash
# Build VRM4U on macOS: compile libassimp.a from the ruyo/assimp fork (the
# ThirdParty/assimp/lib/Mac dir ships only a dummy.txt). Optionally deploy
# the plugin source (with the built libassimp.a) into a global UE install's
# Engine/Plugins/Marketplace dir, where UE will compile it on-demand in the
# correct hierarchy (sibling of other Marketplace plugins like Monolith).
#
# Usage:
#   Scripts/build_vrm4u_mac.sh                      # just build libassimp.a
#   Scripts/build_vrm4u_mac.sh --deploy             # also install into UE engine
#   Scripts/build_vrm4u_mac.sh --deploy --precompile  # also build the dylibs via UBT
#   Scripts/build_vrm4u_mac.sh --force              # wipe assimp build, rebuild
#   Scripts/build_vrm4u_mac.sh --engine /path/to/UE_5.x  # override engine root
#
# Flags can be combined. Default engine root is /Volumes/MySSD/EpicGames/UE_5.7.
# libassimp.a is universal (arm64 + x86_64). --deploy rsyncs source only.
# --precompile additionally invokes UBT against a stub HostProject to build
# the eight VRM4U module dylibs into Engine/Plugins/Marketplace/VRM4U/
# Binaries/Mac so blueprint-only projects can load the plugin without the
# "Engine modules cannot be compiled at runtime" error.

set -euo pipefail

# ─── defaults / arg parsing ──────────────────────────────────────────────────
ENGINE_ROOT="/Volumes/MySSD/EpicGames/UE_5.7"
FORCE=0
DEPLOY=0
PRECOMPILE=0

usage() { sed -n '2,20p' "$0" | sed 's/^# \{0,1\}//'; }

while [[ $# -gt 0 ]]; do
  case "$1" in
    --force)        FORCE=1; shift ;;
    --deploy)       DEPLOY=1; shift ;;
    --precompile)   PRECOMPILE=1; DEPLOY=1; shift ;;
    --engine)       ENGINE_ROOT="${2:?--engine needs a path}"; shift 2 ;;
    --engine=*)     ENGINE_ROOT="${1#*=}"; shift ;;
    --help|-h)      usage; exit 0 ;;
    *)              echo "unknown flag: $1" >&2; usage; exit 2 ;;
  esac
done

# ─── paths ───────────────────────────────────────────────────────────────────
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
UPLUGIN="$PROJECT_ROOT/VRM4U.uplugin"

if [[ ! -f "$UPLUGIN" ]]; then
  echo "error: VRM4U.uplugin not found at $UPLUGIN" >&2
  echo "       this script must live in <VRM4U>/Scripts/" >&2
  exit 1
fi

INSTALL_LIB="$PROJECT_ROOT/ThirdParty/assimp/lib/Mac/libassimp.a"
WORK_DIR="$PROJECT_ROOT/Intermediate/VRM4UMacBuild"
ASSIMP_SRC="$WORK_DIR/assimp-src"
ASSIMP_BUILD="$WORK_DIR/assimp-build"
ASSIMP_REPO="https://github.com/ruyo/assimp.git"
DEPLOY_DIR="$ENGINE_ROOT/Engine/Plugins/Marketplace/VRM4U"

PRECOMPILE_HOST="$WORK_DIR/PrecompileHost"
UBT_BUILD_SH="$ENGINE_ROOT/Engine/Build/BatchFiles/Mac/Build.sh"

echo "→ project root:   $PROJECT_ROOT"
echo "→ engine root:    $ENGINE_ROOT"
echo "→ install lib:    $INSTALL_LIB"
[[ $DEPLOY -eq 1     ]] && echo "→ deploy target:  $DEPLOY_DIR"
[[ $PRECOMPILE -eq 1 ]] && echo "→ precompile via: $UBT_BUILD_SH"

# ─── prereqs ─────────────────────────────────────────────────────────────────
require() {
  local cmd="$1" hint="$2"
  if ! command -v "$cmd" >/dev/null 2>&1; then
    echo "error: '$cmd' not in PATH. install with: $hint" >&2
    exit 1
  fi
}
require git    "xcode-select --install"
require cmake  "brew install cmake"
require clang  "xcode-select --install"

if [[ $DEPLOY -eq 1 && ! -d "$ENGINE_ROOT/Engine" ]]; then
  echo "error: engine root not found at $ENGINE_ROOT" >&2
  echo "       override with --engine /path/to/UE_5.x" >&2
  exit 1
fi
if [[ $PRECOMPILE -eq 1 && ! -x "$UBT_BUILD_SH" ]]; then
  echo "error: UBT Build.sh not executable at $UBT_BUILD_SH" >&2
  exit 1
fi

# ─── build libassimp.a ───────────────────────────────────────────────────────
need_assimp_build=1
if [[ -f "$INSTALL_LIB" && $FORCE -eq 0 ]]; then
  if file "$INSTALL_LIB" | grep -q "current ar archive"; then
    echo "→ libassimp.a already present — skipping assimp build (use --force to rebuild)"
    need_assimp_build=0
  fi
fi

if [[ $need_assimp_build -eq 1 ]]; then
  mkdir -p "$WORK_DIR"
  if [[ $FORCE -eq 1 ]]; then
    echo "→ --force: wiping $ASSIMP_SRC $ASSIMP_BUILD"
    rm -rf "$ASSIMP_SRC" "$ASSIMP_BUILD"
  fi

  if [[ ! -d "$ASSIMP_SRC/.git" ]]; then
    echo "→ cloning ruyo/assimp"
    git clone --depth 1 "$ASSIMP_REPO" "$ASSIMP_SRC"
  else
    echo "→ updating existing assimp clone"
    git -C "$ASSIMP_SRC" fetch --depth 1 origin
    git -C "$ASSIMP_SRC" reset --hard origin/HEAD
  fi

  # BUILD_SHARED_LIBS=OFF + universal binary so the .a works on both archs.
  # Disable tests/tools/Draco/export to minimise the dependency surface.
  echo "→ configuring assimp"
  cmake -S "$ASSIMP_SRC" -B "$ASSIMP_BUILD" \
    -DCMAKE_BUILD_TYPE=Release \
    -DBUILD_SHARED_LIBS=OFF \
    -DCMAKE_OSX_ARCHITECTURES="arm64;x86_64" \
    -DCMAKE_OSX_DEPLOYMENT_TARGET=11.0 \
    -DCMAKE_POLICY_VERSION_MINIMUM=3.5 \
    -DASSIMP_BUILD_TESTS=OFF \
    -DASSIMP_BUILD_ASSIMP_TOOLS=OFF \
    -DASSIMP_BUILD_DRACO=OFF \
    -DASSIMP_BUILD_ZLIB=OFF \
    -DASSIMP_NO_EXPORT=ON \
    -DASSIMP_WARNINGS_AS_ERRORS=OFF \
    -DASSIMP_INSTALL=OFF

  JOBS="$(sysctl -n hw.ncpu 2>/dev/null || echo 4)"
  echo "→ building assimp (parallel=$JOBS)"
  cmake --build "$ASSIMP_BUILD" --config Release --parallel "$JOBS"

  BUILT_LIB=""
  for cand in \
    "$ASSIMP_BUILD/lib/libassimp.a" \
    "$ASSIMP_BUILD/code/libassimp.a" \
    "$ASSIMP_BUILD/bin/libassimp.a"; do
    [[ -f "$cand" ]] && { BUILT_LIB="$cand"; break; }
  done
  if [[ -z "$BUILT_LIB" ]]; then
    echo "error: built libassimp.a not found under $ASSIMP_BUILD" >&2
    exit 1
  fi

  file "$BUILT_LIB"
  if ! file "$BUILT_LIB" | grep -q "Mach-O universal"; then
    echo "warning: output is not a universal binary" >&2
  fi

  mkdir -p "$(dirname "$INSTALL_LIB")"
  # Remove the stub dummy.txt so the dir contains only the real artifact.
  rm -f "$(dirname "$INSTALL_LIB")/dummy.txt"
  cp "$BUILT_LIB" "$INSTALL_LIB"
  echo "→ installed: $INSTALL_LIB"
  file "$INSTALL_LIB"
fi

# ─── deploy ──────────────────────────────────────────────────────────────────
# Install as a Marketplace-level plugin (sibling of Monolith etc.). Source-
# only deploy: UE will compile it into Engine/Plugins/Marketplace/VRM4U/
# Binaries/Mac on the next editor launch of any project that enables it.
# Going via Marketplace (rather than UAT BuildPlugin's HostProject/Plugins
# layout) keeps Monolith → VRM4U as an allowed same-level reference.
if [[ $DEPLOY -eq 1 ]]; then
  mkdir -p "$ENGINE_ROOT/Engine/Plugins/Marketplace"
  echo "→ deploying source to: $DEPLOY_DIR"
  mkdir -p "$DEPLOY_DIR"
  # Exclude build artifacts; libassimp.a is under ThirdParty/ and IS included.
  rsync -a --delete \
    --exclude='.git' \
    --exclude='Intermediate/' \
    --exclude='Saved/' \
    --exclude='Binaries/' \
    --exclude='DerivedDataCache/' \
    "$PROJECT_ROOT/" "$DEPLOY_DIR/"
  echo "→ deployed."
fi

# ─── precompile dylibs via UBT ───────────────────────────────────────────────
# Engine plugins cannot be rebuilt from the editor at runtime ("Engine modules
# cannot be compiled at runtime. Please build through your IDE."). Pre-build
# the editor target of a stub HostProject that enables VRM4U so UBT produces
# UnrealEditor-VRM4U*.dylib under Engine/Plugins/Marketplace/VRM4U/Binaries/Mac.
if [[ $PRECOMPILE -eq 1 ]]; then
  echo "→ generating stub HostProject at $PRECOMPILE_HOST"
  rm -rf "$PRECOMPILE_HOST"
  mkdir -p "$PRECOMPILE_HOST/Source/HostProject" "$PRECOMPILE_HOST/Plugins"

  cat > "$PRECOMPILE_HOST/HostProject.uproject" <<'JSON'
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
JSON

  cat > "$PRECOMPILE_HOST/Source/HostProjectEditor.Target.cs" <<'CS'
using UnrealBuildTool;
public class HostProjectEditorTarget : TargetRules {
  public HostProjectEditorTarget(TargetInfo Target) : base(Target) {
    DefaultBuildSettings = BuildSettingsVersion.Latest;
    IncludeOrderVersion = EngineIncludeOrderVersion.Latest;
    Type = TargetType.Editor;
    ExtraModuleNames.Add("HostProject");
  }
}
CS

  cat > "$PRECOMPILE_HOST/Source/HostProject/HostProject.Build.cs" <<'CS'
using UnrealBuildTool;
public class HostProject : ModuleRules {
  public HostProject(ReadOnlyTargetRules Target) : base(Target) {
    PCHUsage = PCHUsageMode.UseExplicitOrSharedPCHs;
    PrivateDependencyModuleNames.Add("Core");
  }
}
CS

  cat > "$PRECOMPILE_HOST/Source/HostProject/HostProject.cpp" <<'CPP'
// stub
CPP

  # Stage VRM4U as a Project-level plugin inside the HostProject. UBT will
  # happily compile project plugins even into an installed/Rocket engine
  # (where Marketplace/engine plugins are treated as immutable precompiled).
  # The resulting .dylibs are load-time-position-independent and work just
  # as well when later installed at Marketplace level.
  echo "→ staging VRM4U source into HostProject/Plugins/VRM4U"
  mkdir -p "$PRECOMPILE_HOST/Plugins/VRM4U"
  rsync -a --delete \
    --exclude='.git' --exclude='Intermediate/' --exclude='Saved/' \
    --exclude='Binaries/' --exclude='DerivedDataCache/' \
    "$PROJECT_ROOT/" "$PRECOMPILE_HOST/Plugins/VRM4U/"

  echo "→ invoking UBT (this compiles all 8 VRM4U modules — ~5-10 min)"
  # -waitmutex queues behind any in-flight UBT/UAT instead of failing fast.
  "$UBT_BUILD_SH" HostProjectEditor Mac Development \
    -Project="$PRECOMPILE_HOST/HostProject.uproject" \
    -waitmutex

  COMPILED_BIN="$PRECOMPILE_HOST/Plugins/VRM4U/Binaries/Mac"
  if [[ ! -d "$COMPILED_BIN" ]] || ! ls "$COMPILED_BIN"/*.dylib >/dev/null 2>&1; then
    echo "error: UBT finished but no dylibs found at $COMPILED_BIN" >&2
    exit 1
  fi

  echo "→ copying compiled dylibs into engine Marketplace install"
  mkdir -p "$DEPLOY_DIR/Binaries/Mac"
  rsync -a "$COMPILED_BIN/" "$DEPLOY_DIR/Binaries/Mac/"
  echo "→ precompile done:"
  ls -1 "$DEPLOY_DIR/Binaries/Mac"
fi

cat <<EOF

Done.
  libassimp.a : $INSTALL_LIB
$( [[ $DEPLOY -eq 1     ]] && echo "  deployed    : $DEPLOY_DIR" )
$( [[ $PRECOMPILE -eq 1 ]] && echo "  dylibs      : $DEPLOY_DIR/Binaries/Mac" )
EOF
