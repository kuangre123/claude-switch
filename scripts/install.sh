#!/bin/zsh

set -euo pipefail

project_dir=${0:A:h:h}
source_app="$project_dir/dist/Claude Switch.app"
install_dir="$HOME/Applications"
installed_app="$install_dir/Claude Switch.app"

"$project_dir/scripts/build-app.sh" >/dev/null
mkdir -p "$install_dir"
ditto "$source_app" "$installed_app"
open "$installed_app"

echo "已安装并启动：$installed_app"
