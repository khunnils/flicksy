#!/bin/bash
set -euo pipefail

if [[ $# -lt 1 || $# -gt 3 ]]; then
  echo "Usage: $0 test|production [app-store-url creem-product-id]" >&2
  exit 64
fi

mode="$1"
root="$(cd "$(dirname "$0")/../.." && pwd)"
test_config="$root/flicksy-app/Configurations/DirectTest.xcconfig"
production_config="$root/flicksy-app/Configurations/DirectProduction.xcconfig"
project="$root/flicksy-app/Flicksy.xcodeproj/project.pbxproj"

assert_contains() {
  local file="$1" pattern="$2" message="$3"
  grep -Eq "$pattern" "$file" || { echo "$message" >&2; exit 1; }
}

assert_absent() {
  local pattern="$1" message="$2"
  if grep -RIEq "$pattern" \
    "$root/flicksy-app/Configurations" \
    "$root/flicksy-app/Flicksy.xcodeproj" \
    "$root/flicksy-web/src"; then
    echo "$message" >&2
    exit 1
  fi
}

assert_contains "$test_config" 'cloudedminds\.Flicksy\.test' "Direct test bundle ID is missing"
assert_contains "$test_config" 'preview\.flicksy\.me/api/licenses' "Direct test license base is missing"
assert_contains "$test_config" 'TEST_ENVIRONMENT' "Direct test controls are not compile-time isolated"
assert_contains "$production_config" 'FLICKSY_LICENSE_API_URL = https:.+flicksy\.me/api/licenses$' "Production license URL must be the /api/licenses base"
assert_contains "$production_config" 'SPARKLE_FEED_URL = https:.+flicksy\.me/updates/appcast\.xml$' "Production Sparkle feed is incorrect"
assert_contains "$production_config" 'SPARKLE_PUBLIC_ED_KEY = [A-Za-z0-9+/]{40,}={0,2}$' "Production Sparkle public key is missing"

[[ ! -e "$root/flicksy-app/Flicksy/Configuration/Flicksy.storekit" ]] || { echo "StoreKit test configuration must not ship" >&2; exit 1; }
if grep -Eq 'cloudedminds\.Flicksy\.(trial14|lifetime)' "$root/flicksy-app/Flicksy/Services/AppStoreAccessProvider.swift"; then
  echo "App Store provider still contains IAP product IDs" >&2
  exit 1
fi
assert_contains "$root/flicksy-app/Flicksy/Info-AppStore.plist" 'FlicksyAppStoreAppID' "App Store app identity setting is missing"

if [[ "$mode" == "production" ]]; then
  [[ $# -eq 3 ]] || { echo "Production verification requires App Store URL and Creem product ID" >&2; exit 64; }
  app_store_url="$2"
  product_id="$3"
  [[ "$app_store_url" =~ ^https://apps\.apple\.com/.+/id[0-9]+$ ]] || { echo "Production App Store URL is invalid" >&2; exit 1; }
  [[ "$product_id" =~ ^prod_[A-Za-z0-9]+$ && "$product_id" != "prod_2nZWLPHXTxohlTco7vMNl" ]] || { echo "Production Creem product ID is invalid or still the test product" >&2; exit 1; }
  if grep -Eq 'preview\.flicksy\.me|cloudedminds\.Flicksy\.test|TEST_ENVIRONMENT' "$production_config"; then
    echo "Production direct configuration contains test values" >&2
    exit 1
  fi
elif [[ "$mode" != "test" ]]; then
  echo "Unknown mode: $mode" >&2
  exit 64
fi

assert_absent 'flicksy\.app/(api|updates)' "Obsolete flicksy.app endpoint remains in source"
echo "Verified Flicksy $mode source configuration"
