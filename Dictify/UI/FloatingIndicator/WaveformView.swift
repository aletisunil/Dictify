import SwiftUI

struct WaveformView: View {
    let levels: [Float]

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
                        .animation(.spring(response: 0.14, dampingFraction: 0.62), value: level)
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
