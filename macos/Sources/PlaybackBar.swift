import SwiftUI

struct PlaybackBar: View {
    @EnvironmentObject private var model: AppModel

    var body: some View {
        HStack(spacing: 10) {
            Button(action: { model.playRelative(-1) }) {
                Image(systemName: "backward.end.fill")
            }
            .disabled(!model.canUseTransport)

            Button(action: model.togglePause) {
                Image(systemName: model.isPaused ? "play.fill" : "pause.fill")
            }
            .disabled(!model.canUseTransport)

            Button(action: { model.playRelative(1) }) {
                Image(systemName: "forward.end.fill")
            }
            .disabled(!model.canUseTransport)

            Button(action: model.toggleMuted) {
                Image(systemName: model.state.settings.audioMuted ? "speaker.slash.fill" : "speaker.wave.2.fill")
            }

            Text(timeText)
                .font(.caption.monospacedDigit())
                .foregroundStyle(Color.white.opacity(0.82))
                .frame(minWidth: 86, alignment: .leading)

            Slider(
                value: Binding(
                    get: { model.playbackDuration > 0 ? model.playbackPosition / model.playbackDuration : 0 },
                    set: { value in
                        model.isSeeking = true
                        model.seek(value * max(model.playbackDuration, 0.01))
                    }
                ),
                in: 0...1
            ) { editing in
                model.isSeeking = editing
            }
            .disabled(!model.canSeek)

            Picker("倍速", selection: Binding(
                get: { model.state.settings.playbackSpeed },
                set: model.setSpeed
            )) {
                Text("1x").tag(1.0)
                Text("1.25x").tag(1.25)
                Text("1.5x").tag(1.5)
                Text("2x").tag(2.0)
            }
            .labelsHidden()
            .frame(width: 78)
            .disabled(!model.canChangeRate)

            Slider(
                value: Binding(
                    get: { model.state.settings.volume },
                    set: model.setVolume
                ),
                in: 0...100
            )
            .frame(width: 110)

            Button("关电视") { model.toggleTelevision() }
            Button(model.state.settings.bossHidden ? "恢复" : "老板键") { model.toggleBossKey() }
        }
        .buttonStyle(.bordered)
        .controlSize(.small)
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .background(Color(nsColor: NSColor(srgbRed: 17 / 255, green: 24 / 255, blue: 39 / 255, alpha: 1)))
        .foregroundStyle(.white)
    }

    private var timeText: String {
        "\(format(model.playbackPosition)) / \(format(model.playbackDuration))"
    }

    private func format(_ value: Double) -> String {
        let seconds = max(0, Int(value.rounded()))
        return String(format: "%d:%02d", seconds / 60, seconds % 60)
    }
}
