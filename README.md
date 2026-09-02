# Flicksy

Flicksy is a native macOS media browser for organizing, finding, previewing, and comparing images, video, and audio. This repository contains the macOS application and its public website.

## Repository layout

- [`flicksy-app`](flicksy-app/) — the native SwiftUI macOS application and XCTest suite.
- [`flicksy-web`](flicksy-web/) — the Astro marketing website.
- [`branding`](branding/) — logo exploration and exported brand assets.

## Native app development

Requirements:

- macOS 15 or later.
- Xcode with the macOS 15 SDK or later.

Open [`flicksy-app/Flicksy.xcodeproj`](flicksy-app/Flicksy.xcodeproj) in Xcode, select the **Flicksy** scheme and **My Mac**, then run the app with `⌘R`.

You can also build and test from the repository root:

```sh
xcodebuild build \
  -project flicksy-app/Flicksy.xcodeproj \
  -scheme Flicksy \
  -destination 'platform=macOS' \
  CODE_SIGNING_ALLOWED=NO

xcodebuild test \
  -project flicksy-app/Flicksy.xcodeproj \
  -scheme Flicksy \
  -destination 'platform=macOS' \
  CODE_SIGNING_ALLOWED=NO
```

Application code lives in `flicksy-app/Flicksy`, organized into app setup, models, services, state, reusable components, and views. Tests live in `flicksy-app/FlicksyTests`.

## Web development

Requirements:

- Node.js 22.12 or later.
- pnpm 10.13.1 or a compatible pnpm 10 release.

Install dependencies and start the development server:

```sh
cd flicksy-web
pnpm install
pnpm dev
```

The site is available at [http://localhost:4700](http://localhost:4700).

Build and preview the production output with:

```sh
pnpm build
pnpm preview
```

The site source lives in `flicksy-web/src`; static public assets belong in `flicksy-web/public`.

