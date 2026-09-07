# Environment runbook

## Cloudflare configuration

Create the `preview.flicksy.me` and `flicksy.me` custom domains from the `test`
and `production` Wrangler environments. `/api/health` must return HTTP 200 with
both readiness flags true before promoting a production release.

Set `FLICKSY_APP_STORE_URL` in the protected production environment to the live
App Store listing. Keep it unset for test builds until the listing is available.

Remove the obsolete `CREEM_API_KEY` secret and `CREEM_PRODUCT_ID` variable from
the GitHub environments and Cloudflare Worker after this release is deployed.

## Promotion checks

- Test download resolves to `test-latest/Flicksy-Test.dmg`.
- Production has a valid App Store listing URL and no `.test` bundle ID.
- Direct production DMG passes Gatekeeper and notarization checks.
- Appcast signature verifies against the non-placeholder public key.
- The App Store archive contains no direct trial UI or Sparkle and uses the
  paid-app transaction verifier.
