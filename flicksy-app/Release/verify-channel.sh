#!/bin/bash
set -euo pipefail

if [[ $# -ne 2 ]]; then
  echo "Usage: $0 direct-test|direct-production|app-store /path/to/Flicksy.app" >&2
  exit 64
fi

channel="$1"
app_path="$2"
info="$app_path/Contents/Info.plist"
executable="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleExecutable' "$info")"
binary="$app_path/Contents/MacOS/$executable"

[[ -f "$info" && -x "$binary" ]] || { echo "Invalid Flicksy app bundle: $app_path" >&2; exit 66; }

case "$channel" in
  direct-test|direct-production)
    [[ -d "$app_path/Contents/Frameworks/Sparkle.framework" ]] || { echo "Direct build is missing Sparkle.framework" >&2; exit 1; }
    bundle_id="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$info")"
    display_name="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleDisplayName' "$info")"
    checkout_url="$(/usr/libexec/PlistBuddy -c 'Print :FlicksyCheckoutURL' "$info")"
    license_url="$(/usr/libexec/PlistBuddy -c 'Print :FlicksyLicenseAPIURL' "$info")"
    feed_url="$(/usr/libexec/PlistBuddy -c 'Print :SUFeedURL' "$info")"
    public_key="$(/usr/libexec/PlistBuddy -c 'Print :SUPublicEDKey' "$info")"

    if [[ "$channel" == "direct-test" ]]; then
      [[ "$bundle_id" == "cloudedminds.Flicksy.test" && "$display_name" == "Flicksy Test" ]] || { echo "Direct test identity is incorrect" >&2; exit 1; }
      [[ "$checkout_url" == "https://preview.flicksy.me/buy?source=app" ]] || { echo "Direct test checkout URL is incorrect" >&2; exit 1; }
      [[ "$license_url" == "https://preview.flicksy.me/api/licenses" ]] || { echo "Direct test license base URL is incorrect" >&2; exit 1; }
      [[ -z "$feed_url" && -z "$public_key" ]] || { echo "Sparkle must be disabled in Flicksy Test" >&2; exit 1; }
    else
      [[ "$bundle_id" == "cloudedminds.Flicksy" && "$display_name" == "Flicksy" ]] || { echo "Direct production identity is incorrect" >&2; exit 1; }
      [[ "$checkout_url" == "https://flicksy.me/buy?source=app" ]] || { echo "Direct production checkout URL is incorrect" >&2; exit 1; }
      [[ "$license_url" == "https://flicksy.me/api/licenses" ]] || { echo "Direct production license base URL is incorrect" >&2; exit 1; }
      [[ "$feed_url" == "https://flicksy.me/updates/appcast.xml" ]] || { echo "Direct production appcast URL is incorrect" >&2; exit 1; }
      [[ -n "$public_key" && ! "$public_key" =~ REPLACE|PLACEHOLDER|SUPublicEDKey ]] || { echo "Direct production Sparkle public key is missing or a placeholder" >&2; exit 1; }
      if strings "$binary" | grep -Eq 'preview\.flicksy\.me|cloudedminds\.Flicksy\.test|Reset Trial|Expire Trial'; then
        echo "Direct production executable contains test-only configuration or controls" >&2
        exit 1
      fi
    fi
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
    if strings "$binary" | grep -Eqi '/api/licenses|Enter License Key|Deactivate This Mac'; then
      echo "App Store executable unexpectedly contains direct-license code or UI" >&2
      exit 1
    fi
    if find "$app_path" -name 'Flicksy.storekit' -print -quit | grep -q .; then
      echo "App Store build unexpectedly embeds the StoreKit test configuration" >&2
      exit 1
    fi
    if strings "$binary" | grep -Eq 'cloudedminds\.Flicksy\.(trial14|lifetime)|Start 14-Day Free Trial|Restore Purchases|Buy Flicksy'; then
      echo "App Store executable unexpectedly contains trial or in-app purchase behavior" >&2
      exit 1
    fi
    app_id="$(/usr/libexec/PlistBuddy -c 'Print :FlicksyAppStoreAppID' "$info")"
    [[ "$app_id" =~ ^[0-9]+$ ]] || { echo "App Store app ID is missing" >&2; exit 1; }
    ;;
  *)
    echo "Unknown channel: $channel" >&2
    exit 64
    ;;
esac

codesign --verify --deep --strict --verbose=2 "$app_path"
echo "Verified $channel archive: $app_path"
