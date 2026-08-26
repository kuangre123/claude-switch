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

mkdir -p "$build_dir/modules" "$CLANG_MODULE_CACHE_PATH" "$SWIFT_MODULECACHE_PATH"

swiftc \
  -parse-as-library \
  -whole-module-optimization \
  -O \
  -emit-module \
  -emit-object \
  -module-name ClaudeSwitchCore \
  "$project_dir"/Sources/ClaudeSwitchCore/*.swift \
  -framework Security \
  -o "$build_dir/ClaudeSwitchCore.o" \
  -emit-module-path "$build_dir/modules/ClaudeSwitchCore.swiftmodule"

swiftc \
  -parse-as-library \
  -O \
  "$project_dir"/Sources/ClaudeSwitch/*.swift \
  "$build_dir/ClaudeSwitchCore.o" \
  -I "$build_dir/modules" \
  -framework AppKit \
  -framework Security \
  -o "$build_dir/ClaudeSwitch"

mkdir -p "$app_dir/Contents/MacOS" "$app_dir/Contents/Resources"
cp "$build_dir/ClaudeSwitch" "$app_dir/Contents/MacOS/ClaudeSwitch"
cp "$project_dir/Resources/Info.plist" "$app_dir/Contents/Info.plist"
cp "$project_dir/Resources/AppIcon.icns" "$app_dir/Contents/Resources/AppIcon.icns"
chmod 755 "$app_dir/Contents/MacOS/ClaudeSwitch"

codesign --force --deep --sign - "$app_dir" >/dev/null
echo "$app_dir"
