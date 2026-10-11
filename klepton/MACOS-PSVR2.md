# Native macOS host and PSVR2 preview

This experimental path runs Klepton's ARM64 Linux Alyx guest natively on Apple Silicon macOS, then presents its stereo frames through an already installed Metal-capable OpenXR runtime. It does not use visionOS, a VM, or CrossOver. The source tree contains the host and PSVR2 frontend; you must supply the game files, the Linux ARM64 sysroot, MoltenVK, SDL2 compatibility library, OpenXR headers/loader, and a PSVR2 runtime yourself.

The game and its assets remain in the owner’s Steam installation. Do not commit or redistribute game files, shaders, translated proprietary libraries, Steam account data, runtime binaries, calibration data, or headset captures.

## Build prerequisites

- Apple Silicon Mac with Xcode command-line tools and the macOS 27 SDK (the current frontend uses Metal OpenXR and was built with deployment target 27).
- This repository's documented Klepton dependencies and build products, including LuaJIT and Fossilize. Follow [BUILDING.md](BUILDING.md); do not run `make clean` if its build directory contains user state you need.
- Khronos OpenXR-SDK-Source headers and a compatible macOS `libopenxr_loader.dylib` built with `XR_KHR_metal_enable` support.
- MoltenVK and the project's SDL2 compatibility dylib.
- A PSVR2 runtime that publishes a Vulkan graphics device interoperable with MoltenVK's Metal device, a connected headset, and Sense controllers.
- The owner's Steam `game/` directory and an ARM64 Linux sysroot containing the guest's required C/C++ runtime libraries.

Build from `klepton/`, providing paths for the OpenXR checkout and loader directory:

```sh
cd klepton
MACOSX_DEPLOYMENT_TARGET=27.0 make -j4 build/m_alyx \
  ALYX_XR_SDK=/path/to/OpenXR-SDK-Source \
  ALYX_XR_GENERATED_INCLUDE=/path/to/generated/openxr/includes \
  ALYX_XR_LIB=/path/to/macos/openxr/loader
codesign --force --sign - build/m_alyx
codesign --verify --strict build/m_alyx
```

Leave `ALYX_XR_GENERATED_INCLUDE` empty when the selected SDK places all required headers in its `include/` directory. The loader dylib must be available to dyld when launching the driver; arrange its location and runpath for your runtime installation.

## Launch

Start the compatible PSVR2 OpenXR service using its own documented procedure. Do not replace an active service or change the system runtime registration for this preview. Then run:

```sh
export KL_MVK_DIR=/path/to/moltenvk
export KL_SDL2_DYLIB=/path/to/libSDL2-2.0.0.dylib
export XR_RUNTIME_JSON=/path/to/openxr-runtime.json
klepton/run_macos_psvr2.sh \
  /path/to/steamapps/common/Half-Life\ Alyx/game \
  /path/to/arm64-sysroot
```

The launcher opens a native Mac control/preview window. In headset mode it hides that window by default, uses the OpenXR runtime's recommended per-eye size, and anchors the virtual eye height at 1.6 metres for each launch. Set `KL_ALYX_EYE_HEIGHT_M` to a value from 0.5 through 2.3 metres to change that height. The anchor is per launch and is not a room-floor measurement.

Optional controls include `KL_ALYX_FIDELITY` (default 3), `KL_ALYX_MSAA` (default 4), `KLVR_EYE_SIZE=WIDTH,HEIGHT` (guest render-size override), and `KL_ALYX_SHOW_PREVIEW=1` (show the desktop preview while in headset mode). Start with the defaults and lower the guest resolution, fidelity, or MSAA if frame pacing or memory use is poor.

## Current status and limits

The native menu rendered on an M4 Pro and a wearer verified headset visibility, head response, hidden preview, and virtual height. The initial 960×768 render override was removed; the runtime recommended 2800×2856 per eye in a later test. A user-reported leftward menu drift has a per-game comparison setting in the local diagnostic launcher; it remains to be verified on another headset run.

A Source 2 level still renders white because an exposure shader input expected as a multisampled array is bound to a single-sample placeholder. Gameplay, audio, authentication, saves, and long-duration stability are not verified. This is a development preview, not a claim that the Mac port is complete.
