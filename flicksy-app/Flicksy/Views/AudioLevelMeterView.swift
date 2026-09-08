import SwiftUI

struct AudioLevelMeterView: View {
    let meter: AudioLevelMeter?
    var compact = false

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack {
                Text("Levels · dBFS").font(.caption).foregroundStyle(.secondary)
                if let meter, meter.isDownmixed {
                    Text("Downmixed").font(.caption2).foregroundStyle(.secondary)
                }
            }
            if let meter, meter.availability == .available {
                ScrollView(.horizontal) {
                    HStack(alignment: .top, spacing: 8) {
                        ForEach(meter.levels.indices, id: \.self) { index in
                            channel(meter.levels[index], label: meter.label(for: index))
                        }
                        VStack {
                            Text("0")
                            Spacer()
                            Text("−30")
                            Spacer()
                            Text("−60")
                        }
                        .font(.system(size: 9).monospacedDigit()).foregroundStyle(.secondary)
                        .frame(height: compact ? 44 : 88).padding(.top, 15)
                    }
                }
                .scrollIndicators(.hidden)
            } else {
                Text(meter?.availability == .unavailable ? "Levels unavailable" : "Play to see levels")
                    .font(.caption2).foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, minHeight: compact ? 44 : 100, alignment: .leading)
            }
        }
        .help("Decoded audio before listening volume. Solid bars show sample peaks; the brighter inner bar shows 300 ms RMS. Click to reset full-scale indicators.")
        .onTapGesture { meter?.clearFullScale() }
    }

    private func channel(_ level: AudioChannelLevel, label: String) -> some View {
        VStack(spacing: 3) {
            Text(label).font(.system(size: 9)).lineLimit(1)
            GeometryReader { geometry in
                ZStack(alignment: .bottom) {
                    RoundedRectangle(cornerRadius: 2).fill(.quaternary)
                    Rectangle().fill(level.fullScale ? Color.red.opacity(0.6) : Color.accentColor.opacity(0.45))
                        .frame(height: geometry.size.height * fraction(level.peakDB))
                    Rectangle().fill(Color.accentColor)
                        .frame(width: 7, height: geometry.size.height * fraction(level.rmsDB))
                    Rectangle().fill(level.fullScale ? Color.red : Color.primary)
                        .frame(height: 1)
                        .offset(y: -geometry.size.height * fraction(level.heldPeakDB))
                }.clipped()
            }
            .frame(width: 22, height: compact ? 44 : 88)
            Text(reading(level.heldPeakDB)).font(.system(size: 9).monospacedDigit())
                .foregroundStyle(level.fullScale ? Color.red : Color.secondary)
            Text(reading(level.rmsDB)).font(.system(size: 9).monospacedDigit()).foregroundStyle(.secondary)
        }
        .frame(width: 34)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(label) level")
        .accessibilityValue("Peak \(reading(level.heldPeakDB)), RMS \(reading(level.rmsDB)) dBFS\(level.fullScale ? ", full scale reached" : "")")
    }
    private func fraction(_ value: Double) -> Double { min(1, max(0, (value + 60) / 60)) }
    private func reading(_ value: Double) -> String { value.isFinite ? String(format: "%.1f", value) : "−∞" }
}
