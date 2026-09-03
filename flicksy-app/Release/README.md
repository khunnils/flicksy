# Flicksy releases

Both release schemes must receive the same `MARKETING_VERSION` and
`CURRENT_PROJECT_VERSION` values. The GitHub workflows do this explicitly.

## One-time store setup

- Lemon Squeezy: create one $19 non-subscription product with perpetual license
  keys and an activation limit of three. Record the numeric store, product, and
  variant IDs as GitHub repository variables.
- App Store Connect: create free non-consumable
  `cloudedminds.Flicksy.trial14` (display name “14-day Trial”) and paid
  non-consumable `cloudedminds.Flicksy.lifetime` (display name “Flicksy
  Lifetime”, US base price $19). Leave Family Sharing disabled.
- Sparkle: run Sparkle’s `generate_keys --account Flicksy` once. Put only the
  public key in `SPARKLE_PUBLIC_ED_KEY`; store the exported private key as the
  `SPARKLE_PRIVATE_KEY` release secret.
- Website: set the three public variables documented in
  `flicksy-web/.env.example` to the final download, checkout, and App Store URLs.

## Direct workflow configuration

Repository variables: `APPLE_TEAM_ID`, `FLICKSY_CHECKOUT_URL`,
`LEMON_STORE_ID`, `LEMON_PRODUCT_ID`, `LEMON_VARIANT_ID`,
`SPARKLE_PUBLIC_ED_KEY`.

Repository secrets: `BUILD_CERTIFICATE_BASE64`, `P12_PASSWORD`,
`KEYCHAIN_PASSWORD`, `APPLE_ID`, `APP_SPECIFIC_PASSWORD`,
`SPARKLE_PRIVATE_KEY`.

The direct workflow archives with Developer ID, exports the app, builds a DMG
with an Applications shortcut, notarizes and staples it, verifies Gatekeeper,
publishes the versioned and stable-name DMGs to GitHub Releases, generates a
signed Sparkle appcast, and commits that feed to
`flicksy-web/public/updates/appcast.xml`.

## App Store workflow configuration

In addition to the signing certificate secrets and `APPLE_TEAM_ID`, configure
`APP_STORE_CONNECT_KEY_ID` and `APP_STORE_CONNECT_ISSUER_ID` as repository
variables and `APP_STORE_CONNECT_PRIVATE_KEY` as a secret. The workflow tests
the dedicated scheme, archives it, proves that the archive has no Sparkle,
Lemon licensing UI, or StoreKit test file, then uploads it to App Store Connect.

Credentials and the Sparkle private key must remain release secrets. The app
contains only Lemon product identifiers and uses the customer-provided key with
Lemon’s public license API.
