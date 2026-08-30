import SwiftUI

struct WaveformView: View {
    let levels: [Float]

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private let barSpacing: CGFloat = 2
    private let minBarWidth: CGFloat = 3
    private let minBarHeight: CGFloat = 3
    private let maxBarHeight: CGFloat = 30

    var body: some View {
        GeometryReader { geometry in
            let displayedLevels = levels.isEmpty ? [Float(0)] : levels
            let barCount = displayedLevels.count
            let spacingWidth = barSpacing * CGFloat(max(barCount - 1, 0))
            let availableBarWidth = max(geometry.size.width - spacingWidth, 0)
            let barWidth = max(availableBarWidth / CGFloat(barCount), minBarWidth)

            HStack(spacing: barSpacing) {
                ForEach(Array(displayedLevels.enumerated()), id: \.offset) { _, level in
                    let clampedLevel = min(max(CGFloat(level), 0), 1)
                    let responsiveLevel = CGFloat(pow(Double(clampedLevel), 0.55))

                    RoundedRectangle(cornerRadius: barWidth / 2)
                        .fill(barGradient)
                        .frame(width: barWidth)
                        .frame(height: minBarHeight + responsiveLevel * (maxBarHeight - minBarHeight))
                        // Bars still track level (the recording indicator must
                        // stay functional); Reduce Motion just drops the spring.
                        .animation(reduceMotion ? nil : .spring(response: 0.14, dampingFraction: 0.62), value: level)
                }
            }
            .frame(width: geometry.size.width, height: maxBarHeight, alignment: .center)
        }
        .frame(height: maxBarHeight)
    }

    private var barGradient: some ShapeStyle {
        LinearGradient(
            colors: [.primary.opacity(0.72), .primary],
            startPoint: .bottom,
            endPoint: .top
        )
    }
}

/// A continuous processing cue that visually carries the recording waveform
/// into the transcription pipeline. A bright crest travels across subdued bars;
/// processing phase changes do not restart the animation.
struct ProcessingWaveformView: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var animationStart = Date()

    private let barCount = 15
    private let barSpacing: CGFloat = 2
    private let minimumBarHeight: CGFloat = 4
    private let maximumBarHeight: CGFloat = 28
    private let cycleDuration: TimeInterval = 1.15

    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 30.0, paused: reduceMotion)) { context in
            GeometryReader { geometry in
                let spacingWidth = barSpacing * CGFloat(barCount - 1)
                let barWidth = max((geometry.size.width - spacingWidth) / CGFloat(barCount), 3)
                let crestPosition = crestPosition(at: context.date)

                HStack(spacing: barSpacing) {
                    ForEach(0..<barCount, id: \.self) { index in
                        let intensity = crestIntensity(
                            at: CGFloat(index),
                            crestPosition: crestPosition
                        )
                        let height = minimumBarHeight
                            + intensity * (maximumBarHeight - minimumBarHeight)

                        RoundedRectangle(cornerRadius: barWidth / 2, style: .continuous)
                            .fill(Color.primary.opacity(0.2))
                            .overlay {
                                RoundedRectangle(cornerRadius: barWidth / 2, style: .continuous)
                                    .fill(Color.primary.opacity(intensity))
                            }
                            .frame(width: barWidth, height: height)
                    }
                }
                .frame(
                    width: geometry.size.width,
                    height: maximumBarHeight,
                    alignment: .center
                )
            }
        }
        .frame(height: maximumBarHeight)
    }

    private func crestPosition(at date: Date) -> CGFloat {
        guard !reduceMotion else { return CGFloat(barCount - 1) / 2 }

        let progress = date.timeIntervalSince(animationStart)
            .truncatingRemainder(dividingBy: cycleDuration) / cycleDuration

        // Start and finish just outside the bars so the loop resets cleanly.
        return CGFloat(progress) * CGFloat(barCount + 3) - 2
    }

    private func crestIntensity(at index: CGFloat, crestPosition: CGFloat) -> CGFloat {
        let distance = index - crestPosition
        let spread: CGFloat = 1.15
        return exp(-(distance * distance) / (2 * spread * spread))
    }
}
