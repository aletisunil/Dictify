import SwiftUI

struct IndicatorView: View {
    @ObservedObject var appState: AppState
    @AppStorage("showElapsedTime") private var showElapsedTime: Bool = true

    var body: some View {
        Group {
            if appState.pipelineState != .idle {
                indicatorContent
                    .frame(width: Constants.UI.indicatorWidth, height: Constants.UI.indicatorHeight)
                    .background(indicatorShape.fill(.ultraThinMaterial))
                    .overlay(
                        indicatorShape
                            .strokeBorder(Color.appAlert, lineWidth: 1.5)
                            .opacity(isNearCap ? 1 : 0)
                    )
                    .clipShape(indicatorShape)
                    .animation(.easeInOut(duration: 0.25), value: isNearCap)
                    .shadow(color: .black.opacity(0.2), radius: 12, y: 4)
            }
        }
    }

    @ViewBuilder
    private var indicatorContent: some View {
        HStack(spacing: 8) {
            if appState.pipelineState.isRecording {
                WaveformView(levels: appState.audioLevels)
                    .frame(maxWidth: .infinity)
                    .frame(height: 30)

                // The countdown shows even with the elapsed time hidden: it
                // warns that capture is about to auto-stop.
                if isNearCap {
                    capCountdownView
                        .fixedSize()
                } else if showElapsedTime {
                    elapsedTimeView
                        .fixedSize()
                }
            } else if appState.pipelineState.isProcessing {
                Spacer(minLength: 0)
                ProcessingWaveformView()
                    .frame(width: 108, height: 30)
                    .accessibilityLabel(appState.pipelineState.statusLabel)
                Spacer(minLength: 0)
            } else {
                Spacer(minLength: 0)
                statusIcon
                contentForState
                Spacer(minLength: 0)
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 6)
    }

    private var indicatorShape: RoundedRectangle {
        RoundedRectangle(cornerRadius: Constants.UI.indicatorCornerRadius, style: .continuous)
    }

    @ViewBuilder
    private var statusIcon: some View {
        switch appState.pipelineState {
        case .recording:
            EmptyView()
        case .transcribing, .refining, .inserting:
            EmptyView()
        case .error:
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(Color.appAlert)
                .font(.system(size: 12))
        case .idle:
            EmptyView()
        }
    }

    @ViewBuilder
    private var contentForState: some View {
        switch appState.pipelineState {
        case .recording:
            EmptyView()
        case .transcribing, .refining, .inserting:
            EmptyView()
        case .error(let message):
            Text(message)
                .font(.system(size: 10, weight: .medium))
                .foregroundStyle(.primary)
                .lineLimit(1)
        case .idle:
            EmptyView()
        }
    }

    private var elapsedTimeView: some View {
        Text(formatTime(appState.recordingElapsed))
            .font(.system(size: 10, weight: .medium, design: .monospaced))
            .foregroundStyle(.secondary)
    }

    /// Seconds until `maxRecordingDuration` auto-stops the capture.
    private var remainingBeforeCap: TimeInterval {
        Constants.Audio.maxRecordingDuration - appState.recordingElapsed
    }

    private var isNearCap: Bool {
        appState.pipelineState.isRecording
            && appState.recordingElapsed > 0
            && remainingBeforeCap <= Constants.Audio.recordingCapWarningLead
    }

    private var capCountdownView: some View {
        let seconds = max(Int(remainingBeforeCap.rounded(.up)), 0)
        return Text(formatTime(TimeInterval(seconds)))
            .font(.system(size: 10, weight: .semibold, design: .monospaced))
            .foregroundStyle(Color.appAlert)
            .accessibilityLabel("Recording stops in \(seconds) seconds")
    }

    private func formatTime(_ seconds: TimeInterval) -> String {
        let mins = Int(seconds) / 60
        let secs = Int(seconds) % 60
        return String(format: "%d:%02d", mins, secs)
    }
}

private extension PipelineState {
    var isRecording: Bool {
        if case .recording = self { return true }
        return false
    }
}
