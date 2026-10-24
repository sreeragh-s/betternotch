import AVFoundation
import Foundation
import Testing
import SortMyMacCore
@testable import SortMyMac

@Test func recordingSinkCheckpointsAndPausePreserveCompletedAudio() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("SortMyMac-RecordingTest-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let sink = RecordingSink(folder: root, epoch: 100, chunk: { _ in }, failure: { _ in })
    let format = AVAudioFormat(standardFormatWithSampleRate: 48_000, channels: 1)!
    let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 48_000)!
    buffer.frameLength = 48_000
    for index in 0..<48000 { buffer.floatChannelData![0][index] = 0.1 }
    for index in 0..<6 { sink.receive(buffer, source: .microphone, time: 100 + Double(index)) }
    await sink.setPaused(true, offset: 0)
    sink.receive(buffer, source: .microphone, time: 106)
    await sink.setPaused(false, offset: 2)
    sink.receive(buffer, source: .microphone, time: 108)
    await sink.finish()
    let manifest = try JSONDecoder().decode([AudioChunk].self, from: Data(contentsOf: root.appendingPathComponent("manifest.json")))
    #expect(manifest.count == 3)
    #expect(abs(manifest.reduce(0) { $0 + $1.duration } - 7) < 0.01)
    #expect(manifest.last?.start == 6)
    for chunk in manifest {
        let audio = try AVAudioFile(forReading: chunk.url)
        #expect(abs(Double(audio.length) / audio.fileFormat.sampleRate - chunk.duration) < 0.01)
    }
}

@MainActor @Test func hubShelfKeepsIdentityAndNavigationIndependentOfOrganization() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("SortMyMac-HubTest-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let url = root.appendingPathComponent("sample.txt"); try Data("test".utf8).write(to: url)
    let model = AppModel()
    await model.hub.start(owner: model, root: root.appendingPathComponent("library"))
    model.hub.receive([url])
    #expect(model.hub.route == .fileActions)
    #expect(model.phase == .idle)
    #expect(model.hub.selectedFiles.first?.id == model.hub.shelf.first?.file.id)
    model.hub.route = .home
    #expect(model.hub.shelf.count == 1)
    await model.hub.persistenceTask?.value
    let other = HubModel(); await other.start(owner: model, root: root.appendingPathComponent("library"))
    #expect(other.shelf.count == 1)
}

@MainActor @Test func keptPreviewSurvivesCacheInvalidationAndRestart() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("SortMyMac-PreviewTest-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let file = root.appendingPathComponent("notes.txt"); try Data("Keep this result".utf8).write(to: file)
    let model = AppModel(), hub = model.hub
    await hub.start(owner: model, root: root.appendingPathComponent("library"))
    hub.receive([file])
    let action = try #require(FileActionDefinition.available(for: hub.selectedFiles).first { $0.kind == .extractText })
    hub.open(action); hub.generatePreview(); await hub.previewTask?.value
    let preview = try #require(hub.previewResult?.outputs.first)
    #expect(preview.path.contains("/Cache/Previews/"))
    hub.keepPreview()
    let output = try #require(hub.jobs.first?.result?.outputs.first)
    #expect(!output.path.contains("/Cache/")); #expect(FileManager.default.fileExists(atPath: output.path))
    hub.settingsChanged(); #expect(hub.previewResult == nil)
    #expect(FileManager.default.fileExists(atPath: output.path))
    await hub.persistenceTask?.value
    let reopened = HubModel(); await reopened.start(owner: model, root: root.appendingPathComponent("library"))
    #expect(reopened.shelf.contains { $0.managed && $0.file.url == output })
    #expect(FileManager.default.fileExists(atPath: output.path))
}
@MainActor @Test func interruptedMeetingRecoversDurableManifestWithoutRestartingCapture() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("SortMyMac-RecoveryTest-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let store = try LibraryStore(url: root.appendingPathComponent("library.sqlite"))
    let meeting = MeetingRecord(title: "Interrupted test")
    try await store.save(meeting, category: "meetings", id: meeting.id.uuidString)
    let folder = try UtilityPaths.directory("Meetings/\(meeting.id.uuidString)", root: root)
    let chunks = [AudioChunk(source: .microphone, url: folder.appendingPathComponent("checkpoint.caf"), start: 0, duration: 5)]
    try JSONEncoder().encode(chunks).write(to: folder.appendingPathComponent("manifest.json"), options: .atomic)
    let model = AppModel(); await model.hub.start(owner: model, root: root)
    let recovered = try #require(model.hub.meetings.first)
    #expect(recovered.status == .interrupted); #expect(recovered.chunks.count == 1); #expect(recovered.duration == 5)
    #expect(!model.hub.recorder.running); #expect(model.hub.activeMeetingID == nil)
    await model.hub.persistenceTask?.value
}
