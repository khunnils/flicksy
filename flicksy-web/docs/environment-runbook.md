# Environment runbook

## Cloudflare and secrets

Create the `preview.flicksy.me` and `flicksy.me` custom domains from the
`test` and `production` Wrangler environments. Store `CREEM_API_KEY` with:

```sh
pnpm wrangler secret put CREEM_API_KEY --env test
pnpm wrangler secret put CREEM_API_KEY --env production
```

Never copy the test key or product into production. `/api/health` must return
HTTP 200 with both readiness flags true before promoting a release.

## Checkout smoke test

Run from the repository root. The CLI wrapper manages its own browser process:

```sh
export PLAYWRIGHT_CLI=/Users/nils/.codex/skills/playwright/scripts/playwright_cli.sh
mkdir -p output/playwright
"$PLAYWRIGHT_CLI" -s=flicksy-checkout open https://preview.flicksy.me
"$PLAYWRIGHT_CLI" -s=flicksy-checkout snapshot
"$PLAYWRIGHT_CLI" -s=flicksy-checkout screenshot --filename=output/playwright/landing.png
```

Follow the direct-buy link and exercise Creem's successful, declined,
insufficient-funds, bad-CVC, and expired-card test cases. Save a screenshot after
each result and capture a trace when diagnosing a failure. Never paste a real
card or live API key into the test environment.

## Branches

Pushes to `dev` deploy `preview.flicksy.me` and, when app sources change, replace
the `test-latest` Flicksy Test DMG. Production stays on `main`.

## Promotion checks

- Test download resolves to `test-latest/Flicksy-Test.dmg`.
- Production contains no preview URL, test product, or `.test` bundle ID.
- Direct production DMG passes Gatekeeper and notarization checks.
- Appcast signature verifies against the non-placeholder public key.
- The App Store archive contains no direct-license or trial UI and uses the
  paid-app transaction verifier.
