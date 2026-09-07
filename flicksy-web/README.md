# Flicksy website

The Astro site is a Cloudflare Worker with two isolated runtime environments:

| Environment | Host | App Store availability | Download |
| --- | --- | --- | --- |
| `test` | `preview.flicksy.me` | unavailable | `test-latest/Flicksy-Test.dmg` |
| `production` | `flicksy.me` | required | stable `Flicksy.dmg` |

The Worker reads `FLICKSY_ENVIRONMENT`, `FLICKSY_SITE_URL`,
`FLICKSY_DIRECT_DOWNLOAD_URL` and `FLICKSY_APP_STORE_URL` as environment
variables. Production requires a valid App Store listing URL.

## Local development

```sh
pnpm install --frozen-lockfile
cp .env.example .dev.vars
pnpm dev
```

`/buy` redirects to the configured App Store listing. `/api/health` reports
environment and configuration readiness.

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
the production App Store URL. The placeholder in `wrangler.jsonc` is
deliberately rejected until the live listing exists.
