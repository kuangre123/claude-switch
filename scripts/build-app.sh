#!/bin/zsh

set -euo pipefail

project_dir=${0:A:h:h}
build_dir=$(mktemp -d /tmp/claude-switch-build.XXXXXX)
app_dir="$project_dir/dist/Claude Switch.app"
export CLANG_MODULE_CACHE_PATH="$build_dir/clang-module-cache"
export SWIFT_MODULECACHE_PATH="$build_dir/swift-module-cache"

cleanup() {
  rm -rf "$build_dir"
}
trap cleanup EXIT

minimum_macos=$(plutil -extract LSMinimumSystemVersion raw "$project_dir/Resources/Info.plist")
for arch in arm64 x86_64; do
  arch_dir="$build_dir/$arch"
  mkdir -p "$arch_dir/modules"
  swiftc -target "$arch-apple-macos$minimum_macos" \
    -parse-as-library -whole-module-optimization -O -emit-module -emit-object \
    -module-name ClaudeSwitchCore "$project_dir"/Sources/ClaudeSwitchCore/*.swift \
    -framework Security -o "$arch_dir/ClaudeSwitchCore.o" \
    -emit-module-path "$arch_dir/modules/ClaudeSwitchCore.swiftmodule"
  swiftc -target "$arch-apple-macos$minimum_macos" \
    -parse-as-library -O "$project_dir"/Sources/ClaudeSwitch/*.swift \
    "$arch_dir/ClaudeSwitchCore.o" -I "$arch_dir/modules" \
    -framework AppKit -framework Security -o "$arch_dir/ClaudeSwitch"
done

mkdir -p "$app_dir/Contents/MacOS" "$app_dir/Contents/Resources"
lipo -create "$build_dir/arm64/ClaudeSwitch" "$build_dir/x86_64/ClaudeSwitch" \
  -output "$app_dir/Contents/MacOS/ClaudeSwitch"
cp "$project_dir/Resources/Info.plist" "$app_dir/Contents/Info.plist"
cp "$project_dir/Resources/AppIcon.icns" "$app_dir/Contents/Resources/AppIcon.icns"
chmod 755 "$app_dir/Contents/MacOS/ClaudeSwitch"

codesign --force --deep --sign - "$app_dir" >/dev/null
echo "$app_dir"
