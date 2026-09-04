# Flicksy website

The Astro site is a Cloudflare Worker with two isolated runtime environments:

| Environment | Host | Commerce | Download |
| --- | --- | --- | --- |
| `test` | `preview.flicksy.me` | Creem test API/product | `test-latest/Flicksy-Test.dmg` |
| `production` | `flicksy.me` | Creem live API/product | stable `Flicksy.dmg` |

The Worker reads `FLICKSY_ENVIRONMENT`, `FLICKSY_SITE_URL`,
`FLICKSY_DIRECT_DOWNLOAD_URL`, `FLICKSY_APP_STORE_URL`, and
`CREEM_PRODUCT_ID` as environment variables. `CREEM_API_KEY` must be stored as
a secret. Test and live keys are rejected when used in the opposite environment.

## Local development

```sh
pnpm install --frozen-lockfile
cp .env.example .dev.vars
# Replace CREEM_API_KEY with a real Creem test key.
pnpm dev
```

The direct purchase starts at `/buy?source=web|app`. Creem returns to
`/purchase/success`, where the signed query and completed checkout are verified
before the license key is displayed. `/api/health` reports only environment and
configuration readiness.

## Verification and deployment

```sh
pnpm check
pnpm test
pnpm build
pnpm dry-run:test
pnpm dry-run:production
```

Deployments use `pnpm deploy:test` or `pnpm deploy:production`. Pushes that
change `flicksy-web` on `dev` deploy `preview.flicksy.me`; the same path on
`main` deploys `flicksy.me`. The validate workflow typechecks, tests, and
dry-runs both Worker environments without publishing. Direct app releases
still rebuild the production Worker so the signed Sparkle appcast ships with
the DMG. GitHub environments supply the matching Cloudflare token and
`CREEM_API_KEY`. The production placeholders in `wrangler.jsonc` are
deliberately rejected until the live Creem product and App Store listing
exist.

Hosted checkout smoke testing uses Playwright CLI and stores evidence in the
repository-level `output/playwright/` directory; see `docs/environment-runbook.md`.
