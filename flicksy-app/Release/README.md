# Flicksy releases

Flicksy ships through two independent channels. The direct channel has a local
14-day trial and Creem license activation. The Mac App Store channel is a $19
paid-upfront app with no in-app products or trial.

## Build identities

| Scheme | Bundle | Services |
| --- | --- | --- |
| `Flicksy - Direct Test` | `cloudedminds.Flicksy.test`, “Flicksy Test” | preview checkout/license API; Sparkle disabled |
| `Flicksy - Direct Production` | `cloudedminds.Flicksy` | live checkout/license API; signed production appcast |
| `Flicksy - App Store` | `cloudedminds.Flicksy` | signed `AppTransaction` verification only |

The direct configurations derive their Keychain service from the bundle ID, so
test trial and license state cannot unlock or consume production state.

## One-time external setup

- Creem: keep the existing sandbox product for `test`. Create a separate live
  $19 one-time product with perpetual license keys and a three-device limit.
- App Store Connect: create Flicksy as a $19 paid app, complete agreements,
  banking and tax, then set `FLICKSY_APP_STORE_APP_ID`, API key values, and the
  final listing URL in the protected GitHub `production` environment. Do not
  create in-app purchase products.
- Cloudflare: use a token that can deploy Workers and manage both custom-domain
  routes. Test and production Creem keys are Worker secrets, never app values.
- Sparkle: the public key is committed in `DirectProduction.xcconfig`; its
  matching private key belongs in the production `SPARKLE_PRIVATE_KEY` secret.

## Workflows

Every main push deploys the test website. `release-direct-test.yml` signs and
notarizes `Flicksy Test`, then replaces the `test-latest/Flicksy-Test.dmg`
prerelease asset. The production workflow requires environment approval,
revalidates the selected commit, publishes the DMG and signed appcast, and
deploys the production Worker from that same checkout.

The App Store workflow creates one signed archive, verifies it contains no
Sparkle, direct-license, trial, purchase, or restore behavior, and uploads that
archive to App Store Connect. Promote the accepted TestFlight build to App Store
release in App Store Connect without rebuilding it.

Run `Release/verify-source.sh test` locally. Production verification additionally
requires the live App Store URL and live Creem product ID. Archive verification
uses `Release/verify-channel.sh` with `direct-test`, `direct-production`, or
`app-store`.
