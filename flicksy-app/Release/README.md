# Flicksy releases

Flicksy has a direct-download trial and a paid Mac App Store app. The direct
build provides a local 14-day trial; users buy and install the App Store copy
when it expires.

## Build identities

| Scheme | Bundle | Services |
| --- | --- | --- |
| `Flicksy - Direct Test` | `me.flicksy.app.test`, “Flicksy Test” | local trial; Sparkle disabled |
| `Flicksy - Direct Production` | `me.flicksy.app` | local trial; signed production appcast; App Store handoff |
| `Flicksy - App Store` | `me.flicksy.app` | signed `AppTransaction` verification only |

The direct configurations derive their Keychain trial service from the bundle
ID, so test trial state cannot unlock or consume production state.

## One-time external setup

- App Store Connect: create Flicksy as a paid app, complete agreements, banking
  and tax, then set `FLICKSY_APP_STORE_APP_ID`, API key values, and the final
  listing URL in the protected GitHub `production` environment. Do not create
  in-app purchase products.
- Cloudflare: use a token that can deploy Workers and manage both custom-domain
  routes.
- Sparkle: the public key is committed in `DirectProduction.xcconfig`; its
  matching private key belongs in the production `SPARKLE_PRIVATE_KEY` secret.

## Workflows

Website changes on `dev` deploy `preview.flicksy.me`; website changes on `main`
deploy `flicksy.me`. App changes on `dev` sign and notarize `Flicksy Test`, then
replace the `test-latest/Flicksy-Test.dmg` prerelease asset. Direct production
releases require a live App Store URL, publish the DMG and signed appcast, and
redeploy the production Worker from the same checkout.

The App Store workflow creates one signed archive, verifies it contains no
Sparkle or trial behavior, and uploads that archive to App Store Connect.

Run `Release/verify-source.sh test` locally. Production verification also
requires the live App Store URL. Archive verification uses
`Release/verify-channel.sh` with `direct-test`, `direct-production`, or
`app-store`.
