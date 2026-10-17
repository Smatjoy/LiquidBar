#!/bin/zsh
# Builds LiquidBar.app into ./build and (optionally) launches it.
#   Scripts/build-app.sh            release build
#   Scripts/build-app.sh debug      debug build
#   Scripts/build-app.sh release --run
set -euo pipefail
cd "${0:A:h}/.."

config=${1:-release}
swift build -c "$config" --product LiquidBar
swift build -c "$config" --product NowPlayingBridge
bin=$(swift build -c "$config" --show-bin-path)

app=build/LiquidBar.app
rm -rf "$app"
mkdir -p "$app/Contents/MacOS" "$app/Contents/Resources"
cp "$bin/LiquidBar" "$app/Contents/MacOS/"
# Loaded by /usr/bin/perl at runtime, so it lives in Resources, not Frameworks.
cp "$bin/libNowPlayingBridge.dylib" "$app/Contents/Resources/"
cp Resources/Info.plist "$app/Contents/"

# Liquid Glass icon: actool turns the Icon Composer bundle into Assets.car
# (the glass renditions) plus AppIcon.icns (the flat fallback).
xcrun actool Resources/AppIcon.icon --compile "$app/Contents/Resources" \
  --app-icon AppIcon --platform macosx --target-device mac \
  --minimum-deployment-target 26.0 \
  --output-partial-info-plist build/AppIcon-partial.plist >/dev/null
rm -f build/AppIcon-partial.plist

# The queue rows' ripple shader. Xcode ships the Metal compiler separately
# (xcodebuild -downloadComponent MetalToolchain); without it the app still
# works, the ripple is just skipped.
air="$(mktemp -d)/Ripple.air"
if xcrun -sdk macosx metal -c Shaders/Ripple.metal -o "$air" 2>/dev/null \
  && xcrun -sdk macosx metallib "$air" -o "$app/Contents/Resources/default.metallib" 2>/dev/null; then
  echo "Compiled Shaders/Ripple.metal"
else
  echo "Metal Toolchain not installed: queue ripple disabled"
fi
rm -rf "${air:h}"

codesign --force --sign - "$app/Contents/Resources/libNowPlayingBridge.dylib"
codesign --force --sign - "$app"
echo "Built $app"

if [[ "${2:-}" == "--run" ]]; then
  pkill -x LiquidBar 2>/dev/null || true
  open "$app"
fi
