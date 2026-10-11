#!/bin/bash
# Run the native ARM64 macOS Alyx host with an already prepared PSVR2 OpenXR runtime.
set -euo pipefail
if [[ $# -lt 2 ]]; then
  echo "Usage: $0 <game-directory> <arm64-sysroot> [Alyx launch arguments...]" >&2
  exit 2
fi
GAME_DIR="$1"; SYSROOT="$2"; shift 2
DRIVER="${KL_ALYX_DRIVER:-$(cd "$(dirname "$0")" && pwd)/build/m_alyx}"
: "${KL_MVK_DIR:?Set KL_MVK_DIR to the directory containing libMoltenVK.dylib}"
: "${KL_SDL2_DYLIB:?Set KL_SDL2_DYLIB to the SDL2 compatibility dylib}"
: "${XR_RUNTIME_JSON:?Set XR_RUNTIME_JSON to a Metal-capable PSVR2 OpenXR runtime manifest}"
[[ -x "$DRIVER" ]] || { echo "Native driver is not executable: $DRIVER" >&2; exit 2; }
[[ -d "$GAME_DIR" && -d "$SYSROOT" ]] || { echo "Game directory or ARM64 sysroot is missing" >&2; exit 2; }
[[ -f "$GAME_DIR/hlvr/gameinfo.gi" ]] || { echo "Not an Alyx game directory: hlvr/gameinfo.gi is missing" >&2; exit 2; }
[[ -f "$XR_RUNTIME_JSON" ]] || { echo "OpenXR runtime manifest is missing: $XR_RUNTIME_JSON" >&2; exit 2; }
export KL_ALYX_MAC_VIEW=1 KL_ALYX_PSVR2=1
export DYLD_LIBRARY_PATH="$(dirname "$DRIVER"):${KL_MVK_DIR}${DYLD_LIBRARY_PATH:+:${DYLD_LIBRARY_PATH}}"
export KL_VK_SPLIT_DYNAMIC_RENDERING="${KL_VK_SPLIT_DYNAMIC_RENDERING:-1}"
export KL_VK_MERGE=0 KL_VK_MSAA_MEMORYLESS=0
if [[ -z "${KLVR_EYE_SIZE:-}" ]]; then unset KLVR_EYE_SIZE; fi
exec "$DRIVER" "$GAME_DIR" "$SYSROOT" --run -vr -vulkan -console -condebug -noasserts \
  -vulkan_disable_ext_dynamic_state_3 -w 1280 -h 720 \
  +vr_fidelity_level_auto 0 +vr_fidelity_level "${KL_ALYX_FIDELITY:-3}" \
  +vr_msaa "${KL_ALYX_MSAA:-4}" "$@"
