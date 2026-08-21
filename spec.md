# macOS Media Browser — Product & Technical Specification

## 1. Overview

Build a lightweight native macOS application for rapidly browsing and previewing local media files.

The application is intended primarily for content creators working with large numbers of images, video clips, and audio assets during workflows such as YouTube production.

The core concept is:

> A faster, media-focused alternative to browsing files with Finder and Quick Look.

The application should prioritize:

- Speed
- Minimal UI
- Fast visual browsing
- Inline media playback
- Rapid video/audio scrubbing
- Native macOS behavior
- Low memory and CPU usage

This is **not** intended to be a Digital Asset Management (DAM) system. Avoid adding project management, complex tagging, cloud storage, editing, or media-library concepts to the MVP.

---

# 2. Technology

Build as a native macOS application.

### Stack

- Swift
- SwiftUI
- AVFoundation
- AVKit
- ImageIO
- AppKit where SwiftUI functionality is insufficient

Target:

- macOS 15+
- Apple Silicon as primary platform

Use native Apple frameworks wherever practical.

Avoid unnecessary third-party dependencies.

---

# 3. Application Layout

The main application uses a two-pane layout.

```text
┌───────────────────────────────────────────────────────────────┐
│ Media Browser                         1×1  2×2  3×3  4×4     │
├────────────────┬──────────────────────────────────────────────┤
│ FOLDERS        │                                              │
│                │   ┌──────────┐ ┌──────────┐ ┌──────────┐   │
│ ▾ YouTube      │   │  image   │ │ video ▶  │ │  image   │   │
│   Philippines  │   │          │ │          │ │          │   │
│   Samurai      │   └──────────┘ └──────────┘ └──────────┘   │
│   Malaysia     │                                              │
│                │   AUDIO                                      │
│ ▾ Assets       │                                              │
│   Music        │   temple-bell.wav                            │
│   SFX          │   ▂▄▆█▆▄▂▁▂▄▇████▆▄▂▁                      │
│                │                                              │
└────────────────┴──────────────────────────────────────────────┘
```

Use `NavigationSplitView` or equivalent native SwiftUI structure.

---

# 4. Root Folders

Users can add one or more root folders that the application is allowed to browse.

Example:

```text
~/Movies/YouTube
~/Pictures/Assets
~/Music/SFX
```

Use `NSOpenPanel` for folder selection.

The application must persist access between launches using macOS security-scoped bookmarks.

Users should be able to:

- Add root folder
- Remove root folder
- Browse descendants of root folder

The application does not modify files.

---

# 5. Smart Folder Sidebar

The left sidebar displays folders beneath the configured root folders.

Only display folders that:

1. Directly contain supported media; or
2. Have descendants containing supported media.

Example filesystem:

```text
YouTube
├── Philippines
│   ├── script.docx
│   ├── scene01.mp4
│   └── thumbnail.png
├── Admin
│   ├── invoice.pdf
│   └── notes.txt
└── Samurai
    └── audio
        └── temple.wav
```

Sidebar:

```text
YouTube
├── Philippines
└── Samurai
    └── audio
```

`Admin` should not appear.

Folders should be represented hierarchically.

Selecting a folder displays the media contained **directly within that folder** in the main browser.

---

# 6. Supported Media

Initial supported categories:

### Images

Support common formats including:

- JPEG
- PNG
- HEIC
- WebP
- TIFF

### Video

Support formats natively playable by AVFoundation, particularly:

- MP4
- MOV
- M4V

### Audio

Support formats natively playable by AVFoundation, particularly:

- WAV
- MP3
- M4A
- AAC
- AIFF

Use `UTType` for media detection rather than maintaining a hardcoded extension-based classification system.

Define approximately:

```swift
enum MediaType {
    case image
    case video
    case audio
}
```

---

# 7. Media Model

A media item should contain at least:

```swift
struct MediaItem: Identifiable {
    let id: UUID
    let url: URL
    let type: MediaType
    let name: String

    var duration: TimeInterval?
    var width: Int?
    var height: Int?
    var fileSize: Int64?
    var modifiedAt: Date?
}
```

Exact implementation can evolve as needed.

---

# 8. Main Browser

The main content area has two sections:

```text
IMAGES & VIDEO
──────────────────────────────

[ thumbnail ] [ thumbnail ]
[ thumbnail ] [ thumbnail ]


AUDIO
──────────────────────────────

filename.wav
▁▂▄▆████▆▄▂▁▂▄▆█▇▅▃▁

filename.wav
▁▁▂█▃▁▁▂▄██▅▂▁
```

Images and videos use a visual grid.

Audio uses full-width waveform rows.

Do not represent audio as square thumbnail cards.

---

# 9. Grid Layout

Allow the user to change the visual grid between:

- 1 column
- 2 columns
- 3 columns
- 4 columns

Toolbar controls:

```text
1×1   2×2   3×3   4×4
```

Keyboard shortcuts:

```text
⌘1    1 column
⌘2    2 columns
⌘3    3 columns
⌘4    4 columns
```

Implement the grid using `LazyVGrid`.

Grid setting should persist between application launches.

---

# 10. Image Thumbnails

Images must be displayed using generated thumbnails.

Do **not** load full-resolution images into grid cells.

Use ImageIO / `CGImageSourceCreateThumbnailAtIndex` or an equivalent efficient native mechanism.

Thumbnail generation should:

- Run asynchronously
- Preserve aspect ratio
- Avoid blocking the UI
- Cache generated thumbnails
- Cancel unnecessary work when cells disappear if practical

A typical target thumbnail size can be approximately 400–800 px depending on display scale and grid size.

---

# 11. Video Thumbnails

Videos should initially appear using a representative poster frame.

Generate poster frames using AVFoundation.

Do not create an active `AVPlayer` for every video displayed in the grid.

Normal state:

```text
┌──────────────────────┐
│                      │
│     poster frame     │
│                      │
│          ▶           │
├──────────────────────┤
│ scene-043.mp4        │
│ 8.3s · 1920×1080     │
└──────────────────────┘
```

Only create/activate playback resources when required.

---

# 12. Inline Video Playback

Videos can be played directly inside their grid cell.

Use `AVPlayer`.

Only a small number of players should be active at once.

Preferably:

- Starting one video pauses the currently playing video.
- Player resources are released when no longer needed.
- Playback should not continue when the corresponding media is no longer visible.

Basic controls:

- Play
- Pause
- Seek
- Replay

Looping short clips may be added later but is not required for the initial implementation.

---

# 13. Video Hover Scrubbing

A major creator-focused feature is rapid visual video scrubbing.

Moving the mouse horizontally across a video thumbnail should preview different points in the clip.

Concept:

```text
0%                           100%
│                              │
00:00 → 00:04 → 00:08 → 00:12
```

Do not continuously seek an active video player if this produces poor performance.

Preferred approach:

```text
AVAsset
   ↓
AVAssetImageGenerator
   ↓
Generate representative frames
   ↓
Cache storyboard frames
   ↓
Mouse X position selects nearest frame
```

Approximately 10–20 preview frames per clip should be sufficient initially.

Generate frames lazily rather than for every video during initial folder scanning.

---

# 14. Audio Waveforms

Audio files should be represented as waveform rows.

Example:

```text
temple-bell.wav               00:14

▁▂▄▆████▆▄▂▁▂▄▆██▇▅▃▁
                ▲
```

Generate waveform data from the audio samples.

Processing flow:

```text
Audio file
   ↓
Read PCM samples
   ↓
Calculate amplitude
   ↓
Downsample
   ↓
Normalized waveform values
   ↓
Cache
```

The UI does not need sample-level precision.

A few hundred waveform values per file should generally be sufficient.

Render the waveform efficiently using SwiftUI `Canvas`, `Path`, or another suitable native drawing mechanism.

---

# 15. Audio Interaction

Audio waveform interaction should support:

### Hover

Moving horizontally across the waveform updates a visual playhead.

Map:

```text
mouseX / waveformWidth
```

to:

```text
position / duration
```

### Click

Clicking a waveform position starts playback from that location.

### Play/Pause

Provide a small play/pause control.

### Optional audition mode

Automatic sound on normal hover should **not** be enabled by default.

A future interaction could support something such as:

```text
Shift + Hover → audition/scrub audio
```

Do not prioritize this for the first MVP.

---

# 16. Full Media Viewer

Clicking/double-clicking an image or video opens a focused media viewer within the application.

Example:

```text
┌────────────────────────────────────────────────────┐
│                                                    │
│                                                    │
│                 FULL MEDIA                         │
│                                                    │
│                                                    │
│          ←       filename       →                  │
└────────────────────────────────────────────────────┘
```

Support:

```text
Esc         Close viewer
←           Previous media
→           Next media
Space       Play/pause video
F           Toggle fullscreen
```

True macOS fullscreen should be supported.

---

# 17. Full Image Viewer

Images should support:

- Fit to window
- 100% view
- Zoom
- Pan

Trackpad gestures should be used where practical.

Desired interactions:

```text
Pinch            Zoom
Drag             Pan
Double click     Toggle fit / 100%
```

---

# 18. Full Video Viewer

Video viewer should provide native playback behavior using AVPlayer / AVPlayerView.

Support:

- Play/pause
- Seeking
- Fullscreen
- Keyboard playback
- Previous/next media navigation

Prefer native macOS controls rather than implementing a custom video player UI unless necessary.

---

# 19. Folder Monitoring

The application should eventually detect filesystem changes automatically.

Use macOS FSEvents or an appropriate native filesystem monitoring API.

Example:

```text
New file exported
      ↓
Filesystem event
      ↓
FolderWatcher
      ↓
Refresh affected folder
      ↓
New media appears
```

Avoid rescanning the entire root hierarchy for every filesystem event.

This can be implemented after the basic MVP works.

---

# 20. Caching

The application should be designed around caching because production folders may contain hundreds or thousands of large media files.

Cache:

- Image thumbnails
- Video poster frames
- Video storyboard frames
- Audio waveform data
- Media metadata

The first implementation can use memory caching.

Persistent caching can be added subsequently.

Suggested eventual location:

```text
~/Library/Application Support/<AppName>/
```

Potential contents:

```text
cache/
    thumbnails/
    storyboards/
    waveforms/

library.sqlite
```

SQLite is **not required for MVP**.

---

# 21. Application State

Use simple native Swift observation/state management.

Example:

```swift
@Observable
final class BrowserModel {
    var rootFolders: [MediaFolder] = []
    var selectedFolder: MediaFolder?
    var gridColumns: Int = 3
    var selectedMedia: MediaItem?
}
```

Avoid introducing architectural frameworks unless a concrete need emerges.

Do not use Redux/TCA or a third-party dependency injection framework for the initial implementation.

---

# 22. Suggested Project Structure

```text
MediaBrowser/
│
├── App/
│   └── MediaBrowserApp.swift
│
├── Models/
│   ├── MediaItem.swift
│   ├── MediaFolder.swift
│   └── MediaType.swift
│
├── Services/
│   ├── FolderScanner.swift
│   ├── ThumbnailService.swift
│   ├── VideoPreviewService.swift
│   ├── MediaMetadataService.swift
│   ├── WaveformService.swift
│   └── FolderWatcher.swift
│
├── Views/
│   ├── MainView.swift
│   ├── FolderSidebar.swift
│   ├── MediaBrowserView.swift
│   ├── MediaGrid.swift
│   ├── MediaCell.swift
│   ├── ImageCell.swift
│   ├── VideoCell.swift
│   ├── AudioSection.swift
│   ├── AudioRow.swift
│   └── MediaViewer.swift
│
└── Components/
    ├── VideoPlayerView.swift
    ├── WaveformView.swift
    └── GridSizePicker.swift
```

Adjust naming where appropriate, but retain separation between:

- Models
- Media/filesystem services
- Views
- Reusable media components

---

# 23. Performance Requirements

Performance is an important product requirement.

The application should remain responsive when browsing folders containing hundreds or thousands of assets.

Follow these rules:

1. Never synchronously decode large images on the main thread.
2. Never create AVPlayers for every visible video.
3. Generate expensive previews lazily.
4. Cache generated previews.
5. Use `LazyVGrid`.
6. Cancel obsolete asynchronous thumbnail/preview work where practical.
7. Avoid rescanning complete directory trees unnecessarily.
8. Avoid loading complete audio files into memory solely to render waveforms where streaming/chunked processing is practical.
9. UI interactions must not wait for metadata extraction.
10. Prefer native optimized Apple media APIs.

---

# 24. Error Handling

Individual broken or unsupported files must not break folder browsing.

If media cannot be decoded:

```text
┌────────────────────┐
│       ⚠︎            │
│ Preview unavailable│
└────────────────────┘
```

Continue displaying other media normally.

Filesystem permission errors should produce an understandable message and allow the user to reselect the root folder.

---

# 25. Context Menu

Media items should eventually provide a standard macOS context menu.

Initial useful actions:

```text
Open
Reveal in Finder
Copy Path
```

Potential later actions:

```text
Open With…
Favorite
Delete
```

Do not implement destructive operations such as Delete until the core browser is stable.

---

# 26. Drag and Drop

Media items should eventually be draggable from the application into other macOS applications.

Primary use case:

```text
Media Browser
     ↓ drag
CapCut / Final Cut / Finder / other editor
```

Use native file URL drag-and-drop behavior.

This is desirable but not required for the first functional milestone.

---

# 27. MVP Scope

The first usable MVP should include:

- Native macOS application
- Root folder selection
- Persistent folder permissions
- Smart media-only folder sidebar
- Image/video grid
- Separate audio section
- Image thumbnails
- Video poster frames
- Inline video playback
- Audio waveform generation
- Inline audio playback
- 1/2/3/4 column layouts
- Focused image/video viewer
- Basic keyboard navigation

The MVP does **not** need:

- Database
- Cloud synchronization
- User accounts
- Tags
- Ratings
- Collections
- Media editing
- AI functionality
- Project management
- Complex preferences
- Destructive filesystem operations

---

# 28. Implementation Milestones

## Milestone 1 — Browser Shell

Implement:

- macOS SwiftUI project
- Main split view
- Root folder selection
- Security-scoped bookmark persistence
- Folder scanning
- Media detection
- Smart sidebar
- Image thumbnails
- Configurable grid

At completion, the user should be able to browse image folders comfortably.

---

## Milestone 2 — Video

Implement:

- Video metadata
- Poster frame generation
- Video cells
- Inline AVPlayer playback
- Ensure only necessary players exist
- Full video viewer

At completion, the application should be useful for reviewing collections of short video clips.

---

## Milestone 3 — Audio

Implement:

- Audio metadata
- Waveform generation
- Waveform rendering
- Click-to-seek
- Play/pause
- Playhead visualization

At completion, images, video and audio can all be reviewed from one interface.

---

## Milestone 4 — Creator UX

Implement:

- Video hover scrubbing
- Keyboard navigation
- Fullscreen
- Image zoom/pan
- Reveal in Finder
- Copy Path
- Drag file to other applications

---

## Milestone 5 — Performance & Polish

Implement:

- Persistent thumbnail cache
- Persistent waveform cache
- Video storyboard cache
- Filesystem monitoring
- Better cancellation of background tasks
- Large-folder performance testing
- Error states
- UI polish

---

# 29. UX Principles

When making implementation decisions, prioritize:

### Fast over feature-rich

The application exists to inspect media rapidly.

### Preview over organization

Do not turn the application into a media-management system.

### Native over custom

Prefer normal macOS interactions, menus, keyboard shortcuts and playback controls.

### Progressive loading

Show the folder immediately and populate previews as they become available.

### Minimal interaction cost

Common workflows should require very few clicks.

For example:

```text
Select folder
      ↓
scan thumbnails visually
      ↓
hover video
      ↓
find clip
      ↓
drag into editor
```

The application should feel closer to **Quick Look + Finder optimized specifically for media creators** than to Lightroom, Premiere, Final Cut, or a DAM.

---

# 30. Future Features

Do not implement these unless specifically requested, but keep them in mind when designing components:

- Favorites
- Simple approved/rejected markers
- Filters: image/video/audio
- Sort by name/date/duration
- Video looping
- Playback speed
- Video In/Out preview markers
- Side-by-side comparison
- Video contact sheets
- Folder search
- Recent folders
- File metadata inspector
- Quick rename
- Additional keyboard shortcuts

These features should not complicate the initial architecture.

---

# 31. Coding Guidelines

The coding assistant should:

- Prefer idiomatic modern Swift.
- Prefer Swift concurrency (`async/await`) for asynchronous media work.
- Keep expensive work off the main actor.
- Keep views relatively small and composable.
- Avoid premature abstractions.
- Avoid third-party dependencies unless clearly justified.
- Add comments where macOS filesystem/security behavior is non-obvious.
- Ensure async media generation handles cancellation.
- Treat performance with large media files as a first-class concern.
- Build incrementally according to the milestones above.

When uncertain between a more complex architecture and a simple native implementation, prefer the simpler implementation unless there is a demonstrated performance or maintainability reason not to.