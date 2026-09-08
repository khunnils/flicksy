import SwiftUI

/// Fixed listening workspace. Playback survives lazy row creation/removal.
struct AudioInspectorPanel: View {
    @Environment(BrowserModel.self) private var model
    @State private var width: CGFloat = 800
    private var session: AudioAuditionController { model.audioAudition }
    private var compact: Bool { width < 640 }
    private var duration: Double? { session.metadata?.duration ?? session.playback?.duration ?? session.item?.duration }
    private var playing: Bool { session.playback?.isPlaying ?? false }

    var body: some View {
        VStack(spacing: 0) {
            Divider()
            if let item = session.item {
                VStack(alignment: .leading, spacing: 12) {
                    transport(item)
                    if compact {
                        waveform(item)
                        AudioLevelMeterView(meter: session.playback?.meter, compact: true)
                    } else {
                        HStack(alignment: .top, spacing: 18) {
                            waveform(item)
                            Divider().frame(height: 148)
                            AudioLevelMeterView(meter: session.playback?.meter)
                                .frame(width: min(260, max(108, CGFloat(session.playback?.meter?.levels.count ?? 2) * 42 + 20)))
                        }
                    }
                }
                .padding(12)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            } else {
                VStack(spacing: 8) {
                    Image(systemName: "waveform").font(.title2).foregroundStyle(.secondary)
                    Text("Select one audio file to audition").font(.callout)
                    Text("Play with Space, or click a waveform to listen from that point.")
                        .font(.caption).foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .frame(height: compact ? 364 : 248)
        .background(.bar)
        .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { width = $0 }
        .onChange(of: model.selectedAudioItem?.contentVersion, initial: true) { _, _ in
            session.load(model.selectedAudioItem)
        }
    }

    private func transport(_ item: MediaItem) -> some View {
        @Bindable var session = session
        return VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(item.name).font(.callout.weight(.medium)).lineLimit(1).truncationMode(.middle)
                Spacer(minLength: 6)
                Text("\(MediaFormatting.clock(self.session.playback?.currentTime) ?? "0:00") / \(MediaFormatting.clock(duration) ?? "—")")
                    .font(.caption.monospacedDigit()).foregroundStyle(.secondary)
            }
            HStack(spacing: 12) {
                transportButton("backward.end.fill", help: "Jump to Start (⌘⇧←)") { model.requestAudioSeek(.start) }
                transportButton("gobackward.5", help: "Rewind 5 Seconds (←)") { model.requestAudioSeek(.rewind) }
                transportButton(playing ? "pause.fill" : "play.fill", help: playing ? "Pause (Space)" : "Play (Space)") {
                    self.session.toggle(item)
                }
                transportButton("goforward.5", help: "Forward 5 Seconds (→)") { model.requestAudioSeek(.forward) }
                transportButton("forward.end.fill", help: "Jump to End (⌘⇧→)") { model.requestAudioSeek(.end) }
                Button { model.isAudioLooping.toggle() } label: {
                    Image(systemName: "repeat").foregroundStyle(model.isAudioLooping ? Color.accentColor : Color.secondary)
                }.buttonStyle(.plain).help("Loop audio or selected range")
                Spacer(minLength: 4)
                Toggle("Range", isOn: $session.rangeEnabled).toggleStyle(.button).controlSize(.small)
                if session.rangeEnabled {
                    Button("Trim to Selection") {
                        if let times = self.session.selectionTimes {
                            model.trimSelectedAudio(start: times.lowerBound, end: times.upperBound)
                        }
                    }
                    .controlSize(.small)
                    .disabled(!session.isPartialSelection || model.isApplyingAudioTrim || !AudioTrimmer.canTrim(url: item.url))
                    .help("Overwrite the file with the selected range")
                }
                if model.isApplyingAudioTrim { ProgressView().controlSize(.small) }
            }
        }
    }

    private func transportButton(_ name: String, help: String, action: @escaping () -> Void) -> some View {
        Button(action: action) { Image(systemName: name).frame(width: 20, height: 22) }
            .buttonStyle(.plain).help(help).accessibilityLabel(help)
    }

    private func waveform(_ item: MediaItem) -> some View {
        VStack(spacing: 4) {
            WaveformView(peaks: session.peaks, progress: session.playback?.progress ?? 0,
                selection: session.rangeEnabled ? session.selection : 0...1,
                minimumSelectionSpan: session.minimumSelectionSpan,
                onSeek: { session.seek($0, in: item, audition: true) },
                onSelectionChange: session.rangeEnabled ? { session.selection = $0 } : nil,
                duration: duration, showsTimeLabels: true,
                onScrub: { fraction, _ in session.seek(fraction, in: item, audition: false) })
                .frame(height: 120)
                .overlay {
                    if session.waveformLoading || session.waveformFailed {
                        Text(session.waveformLoading ? "Loading waveform…" : "Waveform unavailable")
                            .font(.caption).foregroundStyle(.secondary)
                            .padding(4).background(.background).allowsHitTesting(false)
                    }
                }
            HStack {
                ForEach(0..<5) { index in
                    if index > 0 { Spacer(minLength: 0) }
                    Text(MediaFormatting.clock((duration ?? 0) * Double(index) / 4) ?? "—")
                }
            }
            .font(.caption2.monospacedDigit()).foregroundStyle(.secondary)
            if session.isPartialSelection, let times = session.selectionTimes {
                Text("Range \(MediaFormatting.clock(times.lowerBound) ?? "—")–\(MediaFormatting.clock(times.upperBound) ?? "—") · \(MediaFormatting.clock(times.upperBound - times.lowerBound) ?? "—") selected")
                    .font(.caption2.monospacedDigit()).foregroundStyle(.secondary)
            }
        }.frame(maxWidth: .infinity)
    }
}
