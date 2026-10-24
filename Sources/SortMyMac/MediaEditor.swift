@preconcurrency import AVFoundation
import AVKit
import SortMyMacCore
import SwiftUI

@MainActor
final class ClipPlayback: ObservableObject {
    @Published var player: AVPlayer?
    @Published var info: MediaInfo?
    @Published var current = 0.0
    @Published var waveform: [Float] = []
    @Published var thumbnails: [NSImage] = []
    @Published var playing = false
    @Published var error = ""
    @Published var muted = false { didSet { player?.isMuted = muted } }
    @Published var loop = true
    private var observer: Any?
    private var endObserver: NSObjectProtocol?
    private var start = 0.0, end = 0.0
    func load(_ url: URL) async {
        close()
        do {
            let info = try await MediaProcessor.info(url); try Task.checkCancellation(); self.info = info
            let player = AVPlayer(url: url); self.player = player; end = info.duration
            observer = player.addPeriodicTimeObserver(forInterval: CMTime(seconds: 0.08, preferredTimescale: 600), queue: .main) { [weak self] time in Task { @MainActor in self?.current = time.seconds; self?.playing = self?.player?.rate != 0 } }
            endObserver = NotificationCenter.default.addObserver(forName: .AVPlayerItemDidPlayToEndTime, object: player.currentItem, queue: .main) { [weak self] _ in Task { @MainActor in
                guard let self else { return }
                if self.loop { self.seek(self.start); self.player?.play() } else { self.playing = false }
            } }
            if info.hasVideo {
                let generator = AVAssetImageGenerator(asset: AVURLAsset(url: url)); generator.appliesPreferredTrackTransform = true; generator.maximumSize = CGSize(width: 100, height: 60)
                for index in 0..<12 {
                    try Task.checkCancellation()
                    if let (image, _) = try? await generator.image(at: CMTime(seconds: info.duration * Double(index) / 12, preferredTimescale: 600)) { thumbnails.append(NSImage(cgImage: image, size: .zero)) }
                }
            } else {
                waveform = (try? await Task.detached { try MediaProcessor.waveform(url) }.value) ?? []
            }
        } catch is CancellationError { close() }
        catch { close(); self.error = error.localizedDescription }
    }
    func setRange(_ settings: ActionSettings) {
        guard let duration = info?.duration, let range = try? MediaProcessor.range(settings: settings, duration: duration) else { return }
        start = range.start.seconds; end = CMTimeRangeGetEnd(range).seconds
        player?.currentItem?.reversePlaybackEndTime = range.start
        player?.currentItem?.forwardPlaybackEndTime = CMTimeRangeGetEnd(range)
        if current < start || current > end { seek(start) }
    }
    func seek(_ seconds: Double) { player?.seek(to: CMTime(seconds: max(start, min(end, seconds)), preferredTimescale: 60_000), toleranceBefore: .zero, toleranceAfter: .zero) }
    func toggle() { guard let player else { return }; if player.rate != 0 { player.pause(); playing = false } else { if current >= end - 0.05 { seek(start) }; player.play(); playing = true } }
    func step(_ count: Int) { player?.pause(); player?.currentItem?.step(byCount: count) }
    func close() {
        player?.pause(); if let observer { player?.removeTimeObserver(observer) }; observer = nil
        if let endObserver { NotificationCenter.default.removeObserver(endObserver) }; endObserver = nil
        player = nil; thumbnails = []; waveform = []; info = nil; playing = false
    }
}

struct MediaEditor: View {
    let url: URL
    @Binding var settings: ActionSettings
    let kind: FileActionKind
    @StateObject private var playback = ClipPlayback()
    var body: some View {
        VStack(spacing: 10) {
            if let player = playback.player {
                if playback.info?.hasVideo == true { InlinePlayer(player: player).frame(maxHeight: .infinity).background(.black, in: RoundedRectangle(cornerRadius: 12)) }
                else { waveform.frame(maxHeight: .infinity).background(Color.primary.opacity(0.03), in: RoundedRectangle(cornerRadius: 12)) }
            } else { ProgressView().frame(maxHeight: .infinity) }
            if let info = playback.info {
                timeline(duration: info.duration)
                HStack {
                    HubIconButton(title: "Play or pause selection", symbol: playback.playing ? "pause.fill" : "play.fill") { playback.toggle() }
                    HubIconButton(title: "Previous frame", symbol: "backward.frame") { playback.step(-1) }.disabled(playback.info?.hasVideo != true)
                    HubIconButton(title: "Next frame", symbol: "forward.frame") { playback.step(1) }.disabled(playback.info?.hasVideo != true)
                    Toggle("Mute", isOn: $playback.muted).toggleStyle(.checkbox)
                    Toggle("Loop selection", isOn: $playback.loop).toggleStyle(.checkbox)
                    Spacer()
                    Text(Duration.seconds(playback.current).formatted(.time(pattern: .minuteSecond))).monospacedDigit().font(.caption)
                }.font(.caption)
                VStack(alignment: .leading, spacing: HubUI.related) {
                    HubFormField("Start (seconds)") {
                        HStack(spacing: HubUI.related) {
                            TextField("Start seconds", value: $settings.start, format: .number.precision(.fractionLength(3))).frame(width: 88).monospacedDigit()
                            Slider(value: $settings.start, in: 0...max(0.001, info.duration), onEditingChanged: { _ in settings.start = min(settings.start, max(0, settings.end - 0.01)) }).accessibilityLabel("Selection start")
                        }
                    }
                    HubFormField("End (seconds)") {
                        HStack(spacing: HubUI.related) {
                            TextField("End seconds", value: $settings.end, format: .number.precision(.fractionLength(3))).frame(width: 88).monospacedDigit()
                            Slider(value: $settings.end, in: 0...max(0.001, info.duration), onEditingChanged: { _ in settings.end = max(settings.end, min(info.duration, settings.start + 0.01)) }).accessibilityLabel("Selection end")
                        }
                    }
                    Text("\(max(0, settings.end - settings.start), specifier: "%.3f")s selected").font(HubUI.caption).monospacedDigit().foregroundStyle(.secondary)
                }.hubPanel()
            }
            if !playback.error.isEmpty { Text(playback.error).font(.caption).foregroundStyle(.orange) }
        }
        .task(id: url) {
            await playback.load(url)
            if let duration = playback.info?.duration, settings.end <= 0 || settings.end > duration { settings.end = kind == .makeGIF ? min(10, duration) : duration }
            playback.setRange(settings)
        }
        .onChange(of: settings) { _, value in playback.setRange(value) }
        .onDisappear { playback.close() }
    }
    private var waveform: some View {
        Canvas { context, size in
            let bins = playback.waveform
            guard !bins.isEmpty else { return }
            for (i, peak) in bins.enumerated() {
                let x = Double(i) / Double(bins.count) * size.width
                let h = max(2, Double(peak) * size.height * 0.8)
                context.fill(Path(CGRect(x: x, y: (size.height - h) / 2, width: max(1, size.width / Double(bins.count) - 1), height: h)), with: .color(.accentColor))
            }
        }.accessibilityLabel("Audio waveform")
    }
    private func timeline(duration: Double) -> some View {
        GeometryReader { geometry in
            let width = geometry.size.width
            ZStack(alignment: .leading) {
                HStack(spacing: 1) { ForEach(Array(playback.thumbnails.enumerated()), id: \.offset) { _, image in Image(nsImage: image).resizable().scaledToFill().frame(width: max(1, width / 12), height: 48).clipped() } }
                    .frame(maxWidth: .infinity, maxHeight: .infinity).background(Color.accentColor.opacity(0.12))
                    .contentShape(Rectangle()).gesture(DragGesture(minimumDistance: 0).onChanged { playback.seek($0.location.x / width * duration) })
                let left = max(0, min(width, settings.start / duration * width)), right = max(left, min(width, settings.end / duration * width))
                Rectangle().fill(.black.opacity(0.5)).frame(width: left).allowsHitTesting(false)
                Rectangle().fill(.black.opacity(0.5)).frame(width: max(0, width - right)).offset(x: right).allowsHitTesting(false)
                RoundedRectangle(cornerRadius: 4).stroke(Color.accentColor, lineWidth: 2).frame(width: max(0, right - left)).offset(x: left).allowsHitTesting(false)
                handle.offset(x: left - 14).gesture(DragGesture(coordinateSpace: .named("clipTimeline")).onChanged { settings.start = max(0, min($0.location.x / width * duration, settings.end - 0.01)) }).accessibilityLabel("Trim start handle")
                handle.offset(x: right - 14).gesture(DragGesture(coordinateSpace: .named("clipTimeline")).onChanged { settings.end = min(duration, max(settings.start + 0.01, $0.location.x / width * duration)) }).accessibilityLabel("Trim end handle")
                Rectangle().fill(.white).frame(width: 1).offset(x: max(0, min(width, playback.current / duration * width))).allowsHitTesting(false)
            }.coordinateSpace(name: "clipTimeline").clipShape(RoundedRectangle(cornerRadius: 6))
        }.frame(height: 48)
    }
    private var handle: some View { RoundedRectangle(cornerRadius: 3).fill(Color.accentColor).frame(width: 10).overlay(Image(systemName: "line.3.horizontal").font(.system(size: 7)).rotationEffect(.degrees(90)).foregroundStyle(.white)).frame(width: 28).contentShape(Rectangle()) }
}
struct InlinePlayer: NSViewRepresentable {
    let player: AVPlayer
    func makeNSView(context: Context) -> AVPlayerView { let view = AVPlayerView(); view.controlsStyle = .none; view.videoGravity = .resizeAspect; return view }
    func updateNSView(_ view: AVPlayerView, context: Context) { view.player = player }
    static func dismantleNSView(_ view: AVPlayerView, coordinator: ()) { view.player?.pause(); view.player = nil }
}
