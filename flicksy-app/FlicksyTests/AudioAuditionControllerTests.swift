import XCTest
@testable import Flicksy

@MainActor
final class AudioAuditionControllerTests: XCTestCase {
    func testSelectionLoadsSilentlyAndChangingSelectionStopsPlayback() {
        let (model, items) = makeModel()
        defer { model.shutdown() }
        model.selectItem(items[0])
        XCTAssertEqual(model.audioAudition.item?.id, items[0].id)
        XCTAssertNil(model.audioAudition.playback)
        XCTAssertFalse(model.isAudioPlaying)
        model.audioAudition.toggle(items[0])
        XCTAssertTrue(model.isAudioPlaying)
        let first = model.audioAudition.playback
        model.selectItem(items[1])
        XCTAssertFalse(first?.isPlaying ?? true)
        XCTAssertFalse(model.isAudioPlaying)
        XCTAssertNil(model.playingAudioID)
        XCTAssertEqual(model.audioAudition.item?.id, items[1].id)
    }

    func testClickAuditionsAndScrubbingPreservesPlaybackState() {
        let (model, items) = makeModel()
        defer { model.shutdown() }
        model.selectItem(items[0])
        model.audioAudition.seek(0.25, in: items[0], audition: false)
        XCTAssertFalse(model.isAudioPlaying)
        XCTAssertEqual(model.audioAudition.playback?.currentTime, 2.5)
        model.audioAudition.seek(0.5, in: items[0], audition: true)
        XCTAssertTrue(model.isAudioPlaying)
        XCTAssertEqual(model.audioAudition.playback?.currentTime, 5)
        model.audioAudition.seek(0.7, in: items[0], audition: false)
        XCTAssertTrue(model.isAudioPlaying)
        model.audioAudition.toggle(items[0])
        model.audioAudition.seek(0.8, in: items[0], audition: false)
        XCTAssertFalse(model.isAudioPlaying)
    }

    func testRangeClampAndKeyboardSeeking() {
        let (model, items) = makeModel()
        defer { model.shutdown() }
        model.selectItem(items[0])
        model.audioAudition.selection = 0.2...0.7
        model.audioAudition.rangeEnabled = true
        model.audioAudition.seek(0.9, in: items[0], audition: false)
        XCTAssertEqual(model.audioAudition.playback?.currentTime, 7)
        model.requestAudioSeek(.start)
        XCTAssertEqual(model.audioAudition.playback?.currentTime, 2)
        model.audioAudition.rangeEnabled = false
        model.requestAudioSeek(.end)
        XCTAssertEqual(model.audioAudition.playback?.currentTime, 10)
    }

    func testTabSwitchAndMultiSelectionReleaseSession() {
        let (model, items) = makeModel()
        defer { model.shutdown() }
        model.audioAudition.toggle(items[0])
        model.selectedItemIDs = Set(items.map(\.id))
        XCTAssertNil(model.audioAudition.item)
        XCTAssertNil(model.audioAudition.playback)
        model.audioAudition.toggle(items[0])
        let player = model.audioAudition.playback
        model.libraryTab = .all
        XCTAssertNil(model.audioAudition.playback)
        XCTAssertFalse(player?.isPlaying ?? true)
        XCTAssertNil(model.playingAudioID)
    }

    private func makeModel() -> (BrowserModel, [MediaItem]) {
        let suite = "AudioAuditionControllerTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        let model = BrowserModel(onboardingStore: OnboardingStore(defaults: defaults),
            libraryRepository: LibraryRepository(databaseURL: FileManager.default.temporaryDirectory.appendingPathComponent("\(suite).sqlite")))
        model.sortKey = .name
        let items = ["a", "b"].map {
            MediaItem(url: URL(fileURLWithPath: "/tmp/\(suite)-\($0).wav"), type: .audio, name: $0, duration: 10)
        }
        model.replaceMediaItemsForTesting(items, tab: .audio)
        addTeardownBlock { defaults.removePersistentDomain(forName: suite) }
        return (model, items)
    }
}
