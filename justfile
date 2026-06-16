# JediCapture — build & install the iOS capture app from the terminal.
#
# Set your signing team once in a local .env (gitignored), then `just` reads it:
#     JEDICAPTURE_TEAM=XXXXXXXXXX
# Run `just team-id` to discover it (after adding your Apple ID to Xcode).
#
# Prereqs (one-time):
#   * Xcode + command-line tools (xcodebuild, xcrun devicectl). Xcode 15+.
#   * On-device iOS platform SDK installed. Xcode 26 ships platforms as separate
#     downloads — if `build` errors "iOS XX is not installed", run `just setup`.
#   * iPhone connected over USB (or paired over Wi-Fi), unlocked & trusted.
#   * Developer Mode ON: Settings > Privacy & Security > Developer Mode (iOS 16+).
#   * Your Apple Developer team id. The cloned project ships UPSTREAM's team,
#     which you are not a member of, so set your own:
#         export JEDICAPTURE_TEAM=XXXXXXXXXX
#     (Apple menu > ... or `security find-identity -v -p codesigning` / the
#      Xcode > Settings > Accounts pane shows the 10-char Team ID.)
#
# Signing is overridden on the xcodebuild command line (automatic signing +
# -allowProvisioningUpdates), so you don't have to edit the .xcodeproj.

set dotenv-load := true   # load JEDICAPTURE_TEAM (and friends) from ./.env

scheme      := "NeRFCapture"
config      := "Debug"
usb_port    := "10080"   # must match USBStreamer.port in the app
bundle_id   := "ai.relari.jedicapture"
team        := env_var_or_default("JEDICAPTURE_TEAM", "2DFGSA53H4")
build_dir   := "build"
app_path    := build_dir / "Build/Products/" + config + "-iphoneos/" + scheme + ".app"

# Show recipes
default:
    @just --list

# One-time: install on-device iOS platform SDK + finish Xcode first-launch (multi-GB).
setup:
    sudo xcodebuild -runFirstLaunch
    xcodebuild -downloadPlatform iOS

# Print your signing Team ID(s) for .env (needs an Apple ID added in Xcode first).
team-id:
    #!/usr/bin/env bash
    ids=$(security find-certificate -a -c "Apple Development" -p 2>/dev/null \
        | openssl x509 -noout -subject 2>/dev/null \
        | grep -oE 'OU=[A-Z0-9]{10}' | sed 's/OU=//' | sort -u)
    if [ -z "$ids" ]; then
        echo "No Apple Development cert found. Add your Apple ID in"
        echo "Xcode > Settings > Accounts (free is fine), then re-run 'just team-id'."
    else
        echo "Team ID(s) — put one in .env as JEDICAPTURE_TEAM:"
        echo "$ids"
    fi

# List connected/paired devices (grab the identifier for `install`/`run`).
devices:
    xcrun devicectl list devices

# Build the .app for a physical device (resolves SPM deps on first run).
build:
    xcodebuild \
        -project NeRFCapture.xcodeproj \
        -scheme {{scheme}} \
        -configuration {{config}} \
        -destination 'generic/platform=iOS' \
        -derivedDataPath {{build_dir}} \
        -allowProvisioningUpdates \
        DEVELOPMENT_TEAM={{team}} \
        PRODUCT_BUNDLE_IDENTIFIER={{bundle_id}} \
        build
    @echo "[build] → {{app_path}}"

# Compile only — no signing, no device needed. Fast way to catch code errors.
compile:
    xcodebuild \
        -project NeRFCapture.xcodeproj \
        -scheme {{scheme}} \
        -configuration {{config}} \
        -destination 'generic/platform=iOS' \
        -derivedDataPath {{build_dir}} \
        CODE_SIGNING_ALLOWED=NO \
        build

# Build then install to a device. Pass the identifier from `just devices`:
#   just install device=00008120-000A1B2C3D4E001E
install device: build
    xcrun devicectl device install app --device {{device}} "{{app_path}}"

# Build, install, and launch on the device.
run device: (install device)
    xcrun devicectl device process launch --device {{device}} {{bundle_id}}

# Tunnel the app's USB stream to localhost over usbmux (needs libimobiledevice).
forward:
    @command -v iproxy >/dev/null || { echo "iproxy not found — run: brew install libimobiledevice"; exit 1; }
    iproxy {{usb_port}}:{{usb_port}}

# Offload recorded session zips from the device over USB → ./pulled/.
pull device:
    mkdir -p pulled
    xcrun devicectl device copy from --device {{device}} \
        --domain-type appDataContainer --domain-identifier {{bundle_id}} \
        --source Documents --destination pulled
    @echo "[pull] session zips → ./pulled/Documents/"

# Remove local build artifacts.
clean:
    rm -rf {{build_dir}}
