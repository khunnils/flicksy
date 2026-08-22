//
//  FileSystemMonitor.swift
//  MediaBrowser
//

import CoreServices
import Foundation

/// Watches authorized roots recursively with FSEvents. The callback contains no
/// filesystem work; `BrowserModel` debounces bursts before starting cancellable
/// background rescans.
final class FileSystemMonitor: @unchecked Sendable {
    private let queue = DispatchQueue(label: "cloudedminds.Flicksy.filesystem-monitor", qos: .utility)
    private let onChange: @MainActor @Sendable () -> Void
    private var stream: FSEventStreamRef?

    init(urls: [URL], onChange: @escaping @MainActor @Sendable () -> Void) {
        self.onChange = onChange
        guard !urls.isEmpty else { return }

        var context = FSEventStreamContext(
            version: 0,
            info: Unmanaged.passUnretained(self).toOpaque(),
            retain: nil,
            release: nil,
            copyDescription: nil
        )

        let callback: FSEventStreamCallback = { _, clientInfo, _, _, _, _ in
            guard let clientInfo else { return }
            let monitor = Unmanaged<FileSystemMonitor>
                .fromOpaque(clientInfo)
                .takeUnretainedValue()
            monitor.deliverChange()
        }

        let flags = FSEventStreamCreateFlags(
            kFSEventStreamCreateFlagFileEvents
                | kFSEventStreamCreateFlagWatchRoot
                | kFSEventStreamCreateFlagUseCFTypes
        )

        stream = FSEventStreamCreate(
            nil,
            callback,
            &context,
            urls.map(\.path) as CFArray,
            FSEventStreamEventId(kFSEventStreamEventIdSinceNow),
            0.35,
            flags
        )

        if let stream {
            FSEventStreamSetDispatchQueue(stream, queue)
            FSEventStreamStart(stream)
        }
    }

    deinit {
        guard let stream else { return }
        FSEventStreamStop(stream)
        FSEventStreamInvalidate(stream)
    }

    private func deliverChange() {
        Task { @MainActor [onChange] in
            onChange()
        }
    }
}
