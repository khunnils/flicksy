# SEO audit — 6 September 2026

Scope: the Astro marketing site in `flicksy-web`, plus read-only checks of https://flicksy.me. No deployment or Search Console changes were made.

## Findings and changes

| Finding | Change |
| --- | --- |
| No configured production origin or canonical tags | Set `https://flicksy.me` as the site origin; every page has a canonical URL without query parameters, fragments, or trailing slashes. Existing help URLs are preserved. |
| Live `/sitemap.xml` returned a 404 | Added a generated sitemap with the homepage, help index, seven content-driven help guides, and three legal pages. API, checkout, and purchase-return routes are excluded. |
| Live robots file contained Cloudflare policy comments but no sitemap reference | Added a robots endpoint advertising the production sitemap. API and checkout entry routes are excluded from crawling; purchase pages remain crawlable so search engines can read their noindex directive. |
| Preview builds and purchase returns had no explicit indexing exclusion | Preview builds emit noindex on static and dynamic pages. Purchase confirmations always emit noindex. Dynamic pages served on other hostnames also emit noindex. |
| Sharing metadata lacked URL, image, site name, and Twitter cards | Added complete metadata using an optimized real app screenshot. |
| No structured data | Added WebSite and SoftwareApplication data matching visible product details, plus breadcrumb data for help pages. No fabricated ratings or reviews; software-app rich-result eligibility is not claimed. |
| Generic search snippet and limited contextual help links | Made the homepage title/description more specific, clarified browsing/comparison headings, and linked relevant features to their help guides. |
| Four eager, full-resolution screenshots | Added responsive WebP images at 640, 1200, and 1784 pixels. Prioritized the hero image; deferred lower screenshots with lazy loading. |

The four original screenshots total roughly 6.5 MB. The four 1200-pixel WebP versions total about 450 KB, approximately 93% smaller. Browser selection varies with viewport and pixel density; this is an asset-size comparison, not a measured Core Web Vitals or ranking improvement.

Mobile verification also found horizontal overflow; clipping horizontal overflow at the document root restored the page to viewport width.

## Maintenance

- Run `pnpm optimize:images` after replacing screenshots. Commit the optimized assets and social preview together with the sources.
- Update the homepage SoftwareApplication offer when the visible price or license terms change.
- Help guides enter the sitemap automatically. Add any new public marketing pages to the sitemap endpoint's page list.
- Build previews with `pnpm build:test` and production with `pnpm build:production`; the build environment controls indexing metadata for prerendered pages.

## After deployment

1. Confirm the live robots response still includes `Sitemap: https://flicksy.me/sitemap.xml` after Cloudflare's managed additions, and that every sitemap URL returns 200.
2. Submit the sitemap in Google Search Console and inspect the homepage plus a help guide. Record impressions, clicks, click-through rate, and indexed pages before comparing changes over subsequent weeks.
3. Measure mobile Core Web Vitals on the deployed site with PageSpeed Insights and Search Console. No field-performance baseline was available during this audit.
4. Replace the existing production App Store placeholder with the verified listing when available. The current fallback is a generic app URL; verify the published destination before promoting that channel.
5. Use Search Console query evidence to prioritize deeper guides for image comparison, local media organization, video scrubbing, and audio preview on Mac. Avoid duplicating the homepage into thin keyword pages.

## Verification

- Astro typecheck: zero errors, warnings, or hints.
- Existing unit suite: all 23 tests pass.
- Production and test builds complete. The adapter emits a prerender-environment warning in both builds, but generates all routes successfully.
- Production output: 11 static pages checked for canonical URLs, indexing metadata, sharing metadata, and one H1; sitemap checked for 12 unique public URLs.
- Preview output: all 11 static pages checked for noindex.
- Local homepage metadata and structured data inspected; responsive layout and image selection checked in the browser. Linked help pages, optimized image responses, and purchase-return noindex passed HTTP checks.
- A stale local Vite dependency error after building was resolved by restarting the development server.

## References

- [Google SEO essentials](https://developers.google.com/search/docs/essentials)
- [Descriptive page titles](https://developers.google.com/search/docs/appearance/title-link)
- [Canonical URLs](https://developers.google.com/search/docs/crawling-indexing/consolidate-duplicate-urls)
- [Sitemap guidance](https://developers.google.com/search/docs/crawling-indexing/sitemaps/build-sitemap)
- [Software application structured data](https://developers.google.com/search/docs/appearance/structured-data/software-app)
