#!/bin/bash
set -euo pipefail

if [[ $# -ne 2 ]]; then
  echo "Usage: $0 direct|app-store /path/to/Flicksy.app" >&2
  exit 64
fi

channel="$1"
app_path="$2"
info="$app_path/Contents/Info.plist"
executable="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleExecutable' "$info")"
binary="$app_path/Contents/MacOS/$executable"

[[ -f "$info" && -x "$binary" ]] || { echo "Invalid Flicksy app bundle: $app_path" >&2; exit 66; }

case "$channel" in
  direct)
    [[ -d "$app_path/Contents/Frameworks/Sparkle.framework" ]] || { echo "Direct build is missing Sparkle.framework" >&2; exit 1; }
    /usr/libexec/PlistBuddy -c 'Print :SUFeedURL' "$info" >/dev/null
    /usr/libexec/PlistBuddy -c 'Print :SUPublicEDKey' "$info" >/dev/null
    ;;
  app-store)
    if find "$app_path" -iname '*sparkle*' -print -quit | grep -q .; then
      echo "App Store build unexpectedly contains Sparkle" >&2
      exit 1
    fi
    if /usr/libexec/PlistBuddy -c 'Print :SUFeedURL' "$info" >/dev/null 2>&1; then
      echo "App Store build unexpectedly contains SUFeedURL" >&2
      exit 1
    fi
    if strings "$binary" | grep -Eqi 'api\.lemonsqueezy\.com|Enter License Key|Deactivate This Mac'; then
      echo "App Store executable unexpectedly contains direct-license code or UI" >&2
      exit 1
    fi
    if find "$app_path" -name 'Flicksy.storekit' -print -quit | grep -q .; then
      echo "App Store build unexpectedly embeds the StoreKit test configuration" >&2
      exit 1
    fi
    ;;
  *)
    echo "Unknown channel: $channel" >&2
    exit 64
    ;;
esac

codesign --verify --deep --strict --verbose=2 "$app_path"
echo "Verified $channel archive: $app_path"
