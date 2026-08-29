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
    private let onChange: @MainActor @Sendable (_ hasStructuralChanges: Bool) -> Void
    private var stream: FSEventStreamRef?

    init(
        urls: [URL],
        onChange: @escaping @MainActor @Sendable (_ hasStructuralChanges: Bool) -> Void
    ) {
        self.onChange = onChange
        guard !urls.isEmpty else { return }

        var context = FSEventStreamContext(
            version: 0,
            info: Unmanaged.passUnretained(self).toOpaque(),
            retain: nil,
            release: nil,
            copyDescription: nil
        )

        let callback: FSEventStreamCallback = { _, clientInfo, eventCount, _, eventFlags, _ in
            guard let clientInfo else { return }
            let monitor = Unmanaged<FileSystemMonitor>
                .fromOpaque(clientInfo)
                .takeUnretainedValue()

            let structuralMask = FSEventStreamEventFlags(
                kFSEventStreamEventFlagItemCreated
                    | kFSEventStreamEventFlagItemRemoved
                    | kFSEventStreamEventFlagItemRenamed
                    | kFSEventStreamEventFlagRootChanged
            )
            let directoryFlag = FSEventStreamEventFlags(kFSEventStreamEventFlagItemIsDir)
            var hasStructuralChanges = false
            for index in 0..<Int(eventCount) {
                let flags = eventFlags[index]
                let changesStructure = flags & structuralMask != 0
                let concernsDirectory = flags & directoryFlag != 0
                    || flags & FSEventStreamEventFlags(kFSEventStreamEventFlagRootChanged) != 0
                if changesStructure && concernsDirectory {
                    hasStructuralChanges = true
                    break
                }
            }
            monitor.deliverChange(hasStructuralChanges: hasStructuralChanges)
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

    private func deliverChange(hasStructuralChanges: Bool) {
        Task { @MainActor [onChange] in
            onChange(hasStructuralChanges)
        }
    }
}
