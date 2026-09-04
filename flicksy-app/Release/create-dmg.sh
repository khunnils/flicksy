#!/bin/bash
set -euo pipefail

if [[ $# -ne 2 ]]; then
  echo "Usage: $0 /path/to/Flicksy.app /path/to/Flicksy.dmg" >&2
  exit 64
fi

app_path="$1"
dmg_path="$2"

if [[ ! -d "$app_path" || "${app_path##*.}" != "app" ]]; then
  echo "Expected a .app bundle at: $app_path" >&2
  exit 66
fi

stage_dir="$(mktemp -d)"
trap 'rm -rf "$stage_dir"' EXIT

app_name="$(basename "$app_path")"
volume_name="${app_name%.app}"
ditto "$app_path" "$stage_dir/$app_name"
ln -s /Applications "$stage_dir/Applications"
mkdir -p "$(dirname "$dmg_path")"
rm -f "$dmg_path"
hdiutil create -volname "$volume_name" -srcfolder "$stage_dir" -ov -format UDZO "$dmg_path"
