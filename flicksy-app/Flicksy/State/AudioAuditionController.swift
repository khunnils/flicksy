import SwiftUI

/// Window-owned transport; rows and the inspector only render this shared state.
@Observable @MainActor
final class AudioAuditionController {
    private weak var model: BrowserModel?
    private(set) var item: MediaItem?
    private(set) var playback: AudioPlayback?
    private(set) var metadata: MediaMetadataService.Metadata?
    private(set) var peaks: [Float] = []
    private(set) var waveformLoading = false
    private(set) var waveformFailed = false
    var rangeEnabled = false { didSet { applyRange() } }
    var selection: ClosedRange<Double> = 0...1 { didSet { applyRange() } }
    @ObservationIgnored private var metadataTask: Task<Void, Never>?
    @ObservationIgnored private var waveformTask: Task<Void, Never>?
    private var duration: Double? { metadata?.duration ?? playback?.duration ?? item?.duration }
    var selectionTimes: ClosedRange<Double>? {
        guard rangeEnabled, let duration, duration > 0 else { return nil }
        return (selection.lowerBound * duration)...(selection.upperBound * duration)
    }
    var minimumSelectionSpan: Double { max(0.005, 0.05 / max(duration ?? 1, 0.05)) }
    var isPartialSelection: Bool { rangeEnabled && (selection.lowerBound > 0.008 || selection.upperBound < 0.992) }

    init(model: BrowserModel) { self.model = model }

    func load(_ next: MediaItem?) {
        guard item?.id != next?.id || item?.contentVersion != next?.contentVersion else { item = next; return }
        tearDown()
        item = next
        guard let next else { return }
        waveformLoading = true
        waveformTask = Task { [weak self] in
            let peaks = await WaveformService.shared.waveform(for: next.url)
            guard !Task.isCancelled, let self else { return }
            self.peaks = peaks ?? []
            self.waveformFailed = peaks == nil
            self.waveformLoading = false
        }
        metadataTask = Task { [weak self] in
            let metadata = await MediaMetadataService.shared.metadata(for: next.url)
            guard !Task.isCancelled, let self else { return }
            self.metadata = metadata
            self.model?.noteListMetadata(for: next.id, metadata)
            self.applyRange()
        }
    }

    @discardableResult private func ensurePlayback() -> AudioPlayback? {
        if let playback { return playback }
        guard let item else { return nil }
        let player = AudioPlayback(url: item.url, duration: duration, meteringEnabled: true)
        player.onPlayingChange = { [weak self] playing in
            guard let self, self.model?.playingAudioID == self.item?.id else { return }
            if self.model?.isAudioPlaying != playing { self.model?.isAudioPlaying = playing }
        }
        playback = player
        applyRange()
        return player
    }

    func syncPlayback() {
        guard let model, model.libraryTab == .audio else { return }
        guard let id = model.playingAudioID else { playback?.pause(); return }
        if item?.id != id, let target = model.audioItems.first(where: { $0.id == id }) { load(target) }
        guard let player = ensurePlayback() else { return }
        if model.isAudioPlaying { if !player.isPlaying { player.play() } }
        else if player.isPlaying { player.pause() }
    }

    func toggle(_ target: MediaItem) {
        guard let model else { return }
        model.selectItem(target)
        load(target)
        if model.playingAudioID == target.id { model.isAudioPlaying.toggle() }
        else { model.playingAudioID = target.id }
    }

    func seek(_ fraction: Double, in target: MediaItem, audition: Bool) {
        guard let model else { return }
        if model.selectedAudioItem?.id != target.id { model.selectItem(target) }
        load(target)
        ensurePlayback()?.seek(toFraction: fraction)
        if audition {
            if model.playingAudioID != target.id { model.playingAudioID = target.id }
            else { model.isAudioPlaying = true }
        }
    }

    func transportSeek(_ kind: AudioSeekKind) {
        guard let player = ensurePlayback() else { return }
        switch kind {
        case .start: player.seek(toFraction: rangeEnabled ? selection.lowerBound : 0)
        case .end: player.seek(toFraction: rangeEnabled ? selection.upperBound : 1)
        case .rewind: player.skip(by: -AudioPlayback.skipInterval)
        case .forward: player.skip(by: AudioPlayback.skipInterval)
        }
    }

    func applyRange() {
        playback?.playbackRange = isPartialSelection ? selectionTimes : nil
        playback?.isLooping = model?.isAudioLooping ?? false
    }

    func tearDown() {
        metadataTask?.cancel(); waveformTask?.cancel()
        metadataTask = nil; waveformTask = nil
        playback?.onPlayingChange = nil
        playback?.tearDown(); playback = nil
        item = nil; metadata = nil; peaks = []
        waveformLoading = false; waveformFailed = false
        rangeEnabled = false; selection = 0...1
    }
}
