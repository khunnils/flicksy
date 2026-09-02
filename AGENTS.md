# Repository guidance

This repository contains two separate products that share the Flicksy name and branding. Determine which project a request targets before making changes.

## Native macOS app: `flicksy-app`

`flicksy-app` is the shipping Flicksy product: a native SwiftUI media browser for macOS 15 and later. It handles local media browsing, previews, image comparison, organization, metadata, and file operations.

- App source: `flicksy-app/Flicksy`
- Tests: `flicksy-app/FlicksyTests`
- Xcode project: `flicksy-app/Flicksy.xcodeproj`
- Scheme: `Flicksy`
- Main shared state: `flicksy-app/Flicksy/State/BrowserModel.swift`

When the user says “app,” “mac app,” “native,” “SwiftUI,” “preview window,” “command palette,” or refers to application behavior, work in `flicksy-app` unless they explicitly say otherwise. Do not implement native product features in the Astro project.

Validate native changes with the most relevant tests and, for completed feature work, the full suite:

```sh
xcodebuild test \
  -project flicksy-app/Flicksy.xcodeproj \
  -scheme Flicksy \
  -destination 'platform=macOS' \
  CODE_SIGNING_ALLOWED=NO
```

## Marketing website: `flicksy-web`

`flicksy-web` is the public-facing Astro marketing site. It is not the implementation of the desktop product.

- Pages and components: `flicksy-web/src`
- Static assets: `flicksy-web/public`
- Local server: `http://localhost:4700`
- Tooling: Node.js 22.12+, pnpm 10.13.1, Astro 7

When the user says “website,” “web,” “landing page,” “marketing page,” or “Astro,” work in `flicksy-web`. The nested `flicksy-web/AGENTS.md` contains additional web-specific development instructions and applies to all work in that directory.

Run web commands from `flicksy-web`:

```sh
pnpm install
pnpm dev
pnpm build
```

## Shared repository areas

- `branding` contains source explorations and final brand exports. Reuse approved assets when appropriate; do not treat it as application or website source code.
- Generated directories such as `flicksy-web/node_modules`, `flicksy-web/dist`, Xcode derived data, `output`, and `tmp` are not source. Do not hand-edit or commit generated contents unless a task explicitly requires an artifact.
- Keep changes scoped to the relevant project. Cross-project updates are appropriate only when the user asks for both products to change or when shared branding/copy must intentionally stay aligned.
