import SwiftUI
import MuurCore
import MuurAudio

/// Real-time audio visualizer driven by the engine FFT tap.
struct VisualizerView: View {
    @EnvironmentObject var model: AppModel
    @EnvironmentObject var player: PlaybackController

    var preset: VisualizerPreset = .spectrumBars

    var body: some View {
        TimelineView(.animation) { context in
            Canvas { graphics, size in
                let spectrum = player.meters.spectrum
                let levels = player.meters.levels
                let time = context.date.timeIntervalSinceReferenceDate
                let accent = Color(hex: model.settings.accent.hex)
                let secondary = MuurTheme.accentViolet
                draw(preset: preset, in: &graphics, size: size,
                     spectrum: spectrum, levels: levels, time: time,
                     accent: accent, secondary: secondary)
            }
        }
        .accessibilityLabel("Audio visualizer")
    }

    // MARK: - Dispatch

    private func draw(preset: VisualizerPreset, in graphics: inout GraphicsContext, size: CGSize,
                      spectrum: [Float], levels: [Float], time: Double,
                      accent: Color, secondary: Color) {
        switch preset {
        case .spectrumBars: bars(in: &graphics, size: size, spectrum: spectrum, mirrored: false, accent: accent, secondary: secondary)
        case .mirrorBars: bars(in: &graphics, size: size, spectrum: spectrum, mirrored: true, accent: accent, secondary: secondary)
        case .circleSpectrum: circle(in: &graphics, size: size, spectrum: spectrum, time: time, accent: accent, secondary: secondary)
        case .waveform: waveform(in: &graphics, size: size, levels: levels, time: time, accent: accent)
        case .particles: particles(in: &graphics, size: size, levels: levels, time: time, accent: accent, secondary: secondary)
        case .catEyes: catEyes(in: &graphics, size: size, levels: levels, accent: accent)
        case .starfield: starfield(in: &graphics, size: size, levels: levels, time: time, accent: accent, secondary: secondary)
        case .vinyl: vinyl(in: &graphics, size: size, levels: levels, time: time, accent: accent, isPlaying: player.isPlaying)
        }
    }

    // MARK: - Helpers

    /// Maps a dB spectrum value (-90…0) to 0…1.
    private func normalized(_ db: Float) -> Double {
        Double(min(max((db + 70) / 70, 0), 1))
    }

    private var level: Double {
        let levels = player.meters.levels
        guard let peak = levels.max() else { return 0 }
        return normalized(peak)
    }

    // MARK: - Presets

    private func bars(in graphics: inout GraphicsContext, size: CGSize, spectrum: [Float], mirrored: Bool,
                      accent: Color, secondary: Color) {
        let count = min(max(spectrum.count, 1), 96)
        let step = max(spectrum.count / count, 1)
        let barWidth = size.width / CGFloat(count)
        for index in 0..<count {
            let value = index * step < spectrum.count ? normalized(spectrum[index * step]) : 0.02
            let height = max(CGFloat(value) * (mirrored ? size.height / 2 : size.height), 2)
            let x = CGFloat(index) * barWidth
            let y = mirrored ? size.height / 2 - height : size.height - height
            let rect = CGRect(x: x + 1, y: y, width: max(barWidth - 2, 1), height: height)
            let fraction = Double(index) / Double(count)
            let color = fraction < 0.7 ? accent : secondary
            graphics.fill(Path(roundedRect: rect, cornerRadius: 2), with: .color(color.opacity(0.4 + 0.6 * value)))
        }
    }

    private func circle(in graphics: inout GraphicsContext, size: CGSize, spectrum: [Float], time: Double,
                        accent: Color, secondary: Color) {
        let center = CGPoint(x: size.width / 2, y: size.height / 2)
        let radius = min(size.width, size.height) * 0.28
        let count = min(max(spectrum.count, 1), 72)
        let step = max(spectrum.count / count, 1)
        var path = Path()
        for index in 0..<count {
            let value = index * step < spectrum.count ? normalized(spectrum[index * step]) : 0.05
            let angle = (Double(index) / Double(count)) * 2 * .pi - .pi / 2
            let inner = radius
            let outer = radius + CGFloat(value) * radius * 0.9
            path.move(to: CGPoint(x: center.x + CGFloat(cos(angle)) * inner, y: center.y + CGFloat(sin(angle)) * inner))
            path.addLine(to: CGPoint(x: center.x + CGFloat(cos(angle)) * outer, y: center.y + CGFloat(sin(angle)) * outer))
        }
        graphics.stroke(path, with: .color(accent), style: StrokeStyle(lineWidth: 3, lineCap: .round))
        // Inner pulsing disc
        let pulse = CGFloat(1 + level * 0.15)
        let disc = Path(ellipseIn: CGRect(x: center.x - radius * 0.85 * pulse, y: center.y - radius * 0.85 * pulse,
                                          width: radius * 1.7 * pulse, height: radius * 1.7 * pulse))
        graphics.fill(disc, with: .color(secondary.opacity(0.25)))
    }

    private func waveform(in graphics: inout GraphicsContext, size: CGSize, levels: [Float], time: Double,
                          accent: Color) {
        let amplitude = size.height * 0.35 * CGFloat(0.2 + level * 0.8)
        var path = Path()
        let steps = 120
        for index in 0...steps {
            let x = size.width * CGFloat(index) / CGFloat(steps)
            let phase = Double(index) / Double(steps) * 6 * .pi + time * 4
            let envelope = sin(.pi * Double(index) / Double(steps))
            let y = size.height / 2 + CGFloat(sin(phase) * envelope) * amplitude
            if index == 0 { path.move(to: CGPoint(x: x, y: y)) } else { path.addLine(to: CGPoint(x: x, y: y)) }
        }
        graphics.stroke(path, with: .color(accent), style: StrokeStyle(lineWidth: 3, lineCap: .round))
        graphics.stroke(path, with: .color(accent.opacity(0.3)), style: StrokeStyle(lineWidth: 9, lineCap: .round))
    }

    private func particles(in graphics: inout GraphicsContext, size: CGSize, levels: [Float], time: Double,
                           accent: Color, secondary: Color) {
        let count = 48
        let energy = level
        for index in 0..<count {
            let seed = Double(index)
            let angle = seed * 2.399 + time * (0.1 + 0.05 * (seed.truncatingRemainder(dividingBy: 3)))
            let distance = (seed.truncatingRemainder(dividingBy: 10) / 10 + time * 0.05).truncatingRemainder(dividingBy: 1)
            let spread = min(size.width, size.height) / 2 * CGFloat(distance) * CGFloat(0.4 + energy)
            let x = size.width / 2 + CGFloat(cos(angle)) * spread
            let y = size.height / 2 + CGFloat(sin(angle)) * spread
            let dotSize = 2 + CGFloat(energy) * 6 * CGFloat((seed.truncatingRemainder(dividingBy: 5)) / 5 + 0.3)
            let rect = CGRect(x: x, y: y, width: dotSize, height: dotSize)
            graphics.fill(Path(ellipseIn: rect), with: .color((index.isMultiple(of: 3) ? secondary : accent).opacity(0.8 - distance * 0.6)))
        }
    }

    private func catEyes(in graphics: inout GraphicsContext, size: CGSize, levels: [Float], accent: Color) {
        let openness = 0.15 + level * 0.85
        let eyeWidth = min(size.width, size.height) * 0.22
        let eyeHeight = eyeWidth * CGFloat(openness)
        let y = size.height / 2
        for side in [0.32, 0.68] as [CGFloat] {
            let center = CGPoint(x: size.width * side, y: y)
            let eye = Path(ellipseIn: CGRect(x: center.x - eyeWidth / 2, y: center.y - eyeHeight / 2,
                                             width: eyeWidth, height: eyeHeight))
            graphics.fill(eye, with: .color(accent))
            // Vertical slit pupil
            let pupilWidth = max(2, eyeWidth * 0.12 * (1 - level * 0.5))
            let pupil = Path(ellipseIn: CGRect(x: center.x - pupilWidth / 2, y: center.y - eyeHeight * 0.45,
                                               width: pupilWidth, height: eyeHeight * 0.9))
            graphics.fill(pupil, with: .color(.black.opacity(0.85)))
        }
    }

    private func starfield(in graphics: inout GraphicsContext, size: CGSize, levels: [Float], time: Double,
                           accent: Color, secondary: Color) {
        let count = 90
        let speed = 0.02 + level * 0.25
        for index in 0..<count {
            let seed = Double(index)
            let baseAngle = seed * 2.17
            let depth = (seed.truncatingRemainder(dividingBy: 7) / 7 + time * speed).truncatingRemainder(dividingBy: 1)
            let scale = 0.05 + depth * depth
            let x = size.width / 2 + CGFloat(cos(baseAngle)) * size.width * CGFloat(scale)
            let y = size.height / 2 + CGFloat(sin(baseAngle)) * size.height * CGFloat(scale)
            let starSize = CGFloat(1 + 3 * depth)
            graphics.fill(Path(ellipseIn: CGRect(x: x, y: y, width: starSize, height: starSize)),
                          with: .color((index.isMultiple(of: 4) ? secondary : accent).opacity(0.25 + depth * 0.75)))
        }
    }

    private func vinyl(in graphics: inout GraphicsContext, size: CGSize, levels: [Float], time: Double,
                       accent: Color, isPlaying: Bool) {
        let center = CGPoint(x: size.width / 2, y: size.height / 2)
        let radius = min(size.width, size.height) * 0.42
        // Disc
        graphics.fill(Path(ellipseIn: CGRect(x: center.x - radius, y: center.y - radius, width: radius * 2, height: radius * 2)),
                      with: .color(.black.opacity(0.9)))
        // Grooves
        for groove in stride(from: 0.55, through: 0.95, by: 0.1) {
            let r = radius * groove
            graphics.stroke(Path(ellipseIn: CGRect(x: center.x - r, y: center.y - r, width: r * 2, height: r * 2)),
                            with: .color(.white.opacity(0.06)), lineWidth: 1)
        }
        // Rotating highlight marker
        let angle = isPlaying ? time * 1.2 : 0
        let markerR = radius * 0.75
        let marker = CGPoint(x: center.x + CGFloat(cos(angle)) * markerR, y: center.y + CGFloat(sin(angle)) * markerR)
        graphics.fill(Path(ellipseIn: CGRect(x: marker.x - 4, y: marker.y - 4, width: 8, height: 8)),
                      with: .color(accent))
        // Label with level pulse
        let labelR = radius * 0.34 * CGFloat(1 + level * 0.08)
        graphics.fill(Path(ellipseIn: CGRect(x: center.x - labelR, y: center.y - labelR, width: labelR * 2, height: labelR * 2)),
                      with: .color(accent.opacity(0.85)))
    }
}

/// Full-screen visualizer with auto-cycling presets (driven by settings).
struct FullScreenVisualizerView: View {
    @EnvironmentObject var model: AppModel
    @EnvironmentObject var player: PlaybackController
    @Environment(\.dismiss) private var dismiss

    private let presets = VisualizerPreset.allCases

    var body: some View {
        TimelineView(.periodic(from: .now, by: max(model.settings.visualizerCycleSeconds, 5))) { context in
            let current = currentPreset(at: context.date)
            ZStack {
                Color.black.ignoresSafeArea()
                VisualizerView(preset: current)
                    .padding(24)
                VStack {
                    HStack {
                        Spacer()
                        Button {
                            dismiss()
                        } label: {
                            Image(systemName: "xmark.circle.fill")
                                .font(.title)
                                .foregroundStyle(.white.opacity(0.7))
                        }
                        .padding(20)
                        .accessibilityLabel("Close visualizer")
                    }
                    Spacer()
                    if let track = player.currentTrack {
                        Text("\(track.displayTitle) — \(track.displayArtist)")
                            .font(.caption)
                            .foregroundStyle(.white.opacity(0.6))
                            .padding(.bottom, 20)
                    }
                }
            }
        }
        #if os(iOS)
        .persistentSystemOverlays(.hidden)
        .statusBarHidden(true)
        #endif
    }

    private func currentPreset(at date: Date) -> VisualizerPreset {
        guard model.settings.visualizerAutoCycle else { return model.settings.visualizerPreset }
        let seconds = max(model.settings.visualizerCycleSeconds, 5)
        let index = Int(date.timeIntervalSinceReferenceDate / seconds) % presets.count
        return presets[index]
    }
}
