import AppKit
import AVFoundation
import ImageIO
import SwiftUI
import VoiceTypeCore

/// What the History window shows: every dictation from the last 30 days, newest first.
/// Main thread; loading, transcribing again and saving a fix happen elsewhere, through
/// `Actions`.
final class HistoryModel: NSObject, ObservableObject, AVAudioPlayerDelegate {
    struct Actions {
        var load: (@escaping ([HistoryItem]) -> Void) -> Void
        /// Nil text means it couldn't be done.
        var retranscribe: (String, @escaping (String?) -> Void) -> Void
        var fix: (String, String, @escaping (Bool) -> Void) -> Void
    }

    struct Day: Identifiable {
        var id: Date
        var title: String
        var items: [HistoryItem]
    }

    private let actions: Actions
    private var player: AVAudioPlayer?
    private var toastTimer: DispatchWorkItem?
    private var loading = false
    private var loadAgain = false

    @Published private(set) var items: [HistoryItem] = []
    @Published private(set) var loaded = false
    @Published var query = ""
    @Published private(set) var playingID: String?
    @Published private(set) var working: Set<String> = []
    @Published private(set) var toast: String?

    init(actions: Actions) {
        self.actions = actions
    }

    /// Reads everything again, e.g. when a dictation finishes while the window is open.
    func reload() {
        guard !loading else {
            loadAgain = true
            return
        }
        loading = true
        actions.load { [weak self] items in
            guard let self else { return }
            self.items = items
            self.loaded = true
            self.loading = false
            if self.loadAgain {
                self.loadAgain = false
                self.reload()
            }
        }
    }

    var days: [Day] {
        let words = PythonText.strip(query)
        let shown = words.isEmpty ? items : items.filter {
            $0.bestText.localizedCaseInsensitiveContains(words) || $0.text.localizedCaseInsensitiveContains(words)
        }
        let calendar = Calendar.current
        var days: [Day] = []
        for item in shown {
            let start = calendar.startOfDay(for: item.date)
            if days.last?.id == start {
                days[days.count - 1].items.append(item)
            } else {
                days.append(Day(id: start, title: Self.dayTitle(start, calendar: calendar), items: [item]))
            }
        }
        return days
    }

    static func dayTitle(_ day: Date, calendar: Calendar) -> String {
        if calendar.isDateInToday(day) { return "Today" }
        if calendar.isDateInYesterday(day) { return "Yesterday" }
        return dayFormatter.string(from: day)
    }

    private static let dayFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.setLocalizedDateFormatFromTemplate("EEEE d MMMM")
        return formatter
    }()

    static let timeFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.timeStyle = .short
        formatter.dateStyle = .none
        return formatter
    }()

    // MARK: Row actions

    func copy(_ item: HistoryItem) {
        let text = item.bestText
        guard !text.isEmpty else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
        show("Copied")
    }

    func togglePlay(_ item: HistoryItem) {
        if playingID == item.id {
            stopPlaying()
            return
        }
        stopPlaying()
        guard let url = item.audioURL else { return }
        do {
            let player = try AVAudioPlayer(contentsOf: url)
            player.delegate = self
            player.play()
            self.player = player
            playingID = item.id
        } catch {
            show("Couldn't play it")
        }
    }

    func stopPlaying() {
        player?.stop()
        player = nil
        playingID = nil
    }

    func audioPlayerDidFinishPlaying(_ player: AVAudioPlayer, successfully flag: Bool) {
        DispatchQueue.main.async { [weak self] in
            guard let self, self.player === player else { return }
            self.player = nil
            self.playingID = nil
        }
    }

    /// One at a time: each waits behind any dictation being finalised, and a queue of them
    /// would hold the next dictation up.
    var canTranscribe: Bool { working.isEmpty }

    func transcribeAgain(_ item: HistoryItem) {
        guard let id = item.recordingID, canTranscribe else { return }
        working.insert(item.id)
        actions.retranscribe(id) { [weak self] text in
            guard let self else { return }
            self.working.remove(item.id)
            guard let text else {
                self.show("Couldn't transcribe it")
                return
            }
            self.change(item.id) { $0.retranscribedText = text }
            if text.isEmpty { self.show("Whisper heard nothing") }
        }
    }

    func fix(_ item: HistoryItem, to text: String) {
        guard let id = item.recordingID else { return }
        let fixed = PythonText.strip(text)
        actions.fix(id, fixed) { [weak self] saved in
            guard let self else { return }
            if saved {
                self.change(item.id) { $0.correctedText = fixed }
                self.show("Saved")
            } else {
                self.show("Couldn't save it")
            }
        }
    }

    func showInFinder(_ item: HistoryItem) {
        guard let url = item.audioURL else { return }
        NSWorkspace.shared.activateFileViewerSelecting([url])
    }

    private func change(_ id: String, _ edit: (inout HistoryItem) -> Void) {
        guard let index = items.firstIndex(where: { $0.id == id }) else { return }
        edit(&items[index])
    }

    private func show(_ message: String) {
        toastTimer?.cancel()
        toast = message
        let timer = DispatchWorkItem { [weak self] in self?.toast = nil }
        toastTimer = timer
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.4, execute: timer)
    }
}

struct HistoryView: View {
    @ObservedObject var model: HistoryModel

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                TextField("Search", text: $model.query)
                    .textFieldStyle(.plain)
                if !model.query.isEmpty {
                    Button { model.query = "" } label: { Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary) }
                        .buttonStyle(.borderless)
                        .help("Clear")
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            Divider()
            content
        }
        .frame(minWidth: 520, minHeight: 360)
        .overlay(alignment: .bottom) {
            if let toast = model.toast {
                Text(toast)
                    .font(.callout.weight(.medium))
                    .padding(.horizontal, 14)
                    .padding(.vertical, 8)
                    .background(.regularMaterial, in: Capsule())
                    .padding(.bottom, 16)
                    .transition(.opacity)
            }
        }
        .animation(.easeOut(duration: 0.15), value: model.toast)
    }

    @ViewBuilder private var content: some View {
        let days = model.days
        if !model.loaded {
            ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if model.items.isEmpty {
            ContentUnavailableView("No Dictations Yet", systemImage: "waveform")
        } else if days.isEmpty {
            ContentUnavailableView.search(text: model.query)
        } else {
            List {
                ForEach(days) { day in
                    Section(day.title) {
                        ForEach(day.items) { item in
                            HistoryRow(item: item, model: model)
                        }
                    }
                }
            }
            .listStyle(.inset)
        }
    }
}

private struct HistoryRow: View {
    let item: HistoryItem
    @ObservedObject var model: HistoryModel
    @State private var fixing = false

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Text(HistoryModel.timeFormatter.string(from: item.date))
                .monospacedDigit()
                .foregroundStyle(.secondary)
                .frame(width: 64, alignment: .leading)
            VStack(alignment: .leading, spacing: 4) {
                mainText
                if let fixed = item.correctedText, !item.text.isEmpty, fixed != item.text {
                    Text(item.text).strikethrough().foregroundStyle(.secondary).font(.callout)
                }
                if !item.screenshots.isEmpty {
                    HStack(spacing: 6) {
                        ForEach(item.screenshots, id: \.self) { Thumbnail(url: $0) }
                    }
                    .padding(.top, 2)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            HStack(spacing: 8) {
                if item.recovered {
                    Image(systemName: "arrow.uturn.backward")
                        .foregroundStyle(.secondary)
                        .help("Recovered after Voice Type was cut off mid-dictation")
                }
                if item.correctedText != nil {
                    Image(systemName: "checkmark.seal")
                        .foregroundStyle(.secondary)
                        .help("Fixed, and kept as a labelled clip")
                }
                if model.working.contains(item.id) {
                    ProgressView().controlSize(.small)
                }
                if let seconds = item.durationSec {
                    Text(Self.duration(seconds)).monospacedDigit().foregroundStyle(.secondary)
                }
                if item.audioURL != nil {
                    Button { model.togglePlay(item) } label: {
                        Image(systemName: model.playingID == item.id ? "stop.fill" : "play.fill")
                    }
                    .buttonStyle(.borderless)
                    .help(model.playingID == item.id ? "Stop" : "Play")
                }
                Menu {
                    Button("Copy") { model.copy(item) }.disabled(item.bestText.isEmpty)
                    if item.recordingID != nil {
                        Button("Fix It...") { fixing = true }
                        Button("Transcribe Again") { model.transcribeAgain(item) }.disabled(!model.canTranscribe)
                        Button("Show in Finder") { model.showInFinder(item) }
                    }
                } label: {
                    Image(systemName: "ellipsis.circle")
                }
                .menuStyle(.borderlessButton)
                .menuIndicator(.hidden)
                .fixedSize()
            }
        }
        .padding(.vertical, 3)
        .contentShape(Rectangle())
        .onTapGesture { model.copy(item) }
        .help(item.bestText.isEmpty ? "" : "Click to copy")
        .popover(isPresented: $fixing, arrowEdge: .bottom) {
            FixItView(text: item.bestText) { text in
                fixing = false
                if let text { model.fix(item, to: text) }
            }
        }
    }

    @ViewBuilder private var mainText: some View {
        if let fixed = item.correctedText {
            Text(fixed).textSelection(.enabled)
        } else if !item.text.isEmpty {
            Text(item.text).textSelection(.enabled)
        } else if let again = item.retranscribedText, !again.isEmpty {
            HStack(alignment: .firstTextBaseline, spacing: 4) {
                Image(systemName: "waveform").foregroundStyle(.secondary).help("Transcribed again; this wasn't typed")
                Text(again).foregroundStyle(.secondary).textSelection(.enabled)
            }
        } else {
            Text(Self.outcomeText(item)).foregroundStyle(.secondary)
        }
    }

    static func outcomeText(_ item: HistoryItem) -> String {
        switch item.outcome {
        case .typed: return ""
        case .nothingTyped: return item.retranscribedText != nil ? "Whisper heard nothing" : "Nothing typed"
        case .noAudio: return "No microphone audio"
        case .failed: return "Failed"
        case .notTranscribed: return "Not transcribed"
        }
    }

    static func duration(_ seconds: Double) -> String {
        seconds < 10 ? String(format: "%.1f s", seconds) : "\(Int(seconds.rounded())) s"
    }
}

/// Type what it should have said.
private struct FixItView: View {
    @State var text: String
    let done: (String?) -> Void

    var body: some View {
        VStack(alignment: .trailing, spacing: 10) {
            TextEditor(text: $text)
                .font(.body)
                .frame(width: 340, height: 90)
                .scrollContentBackground(.hidden)
                .padding(4)
                .background(.background, in: RoundedRectangle(cornerRadius: 6))
                .overlay(RoundedRectangle(cornerRadius: 6).stroke(.separator))
            HStack {
                Button("Cancel") { done(nil) }.keyboardShortcut(.cancelAction)
                Button("Save") { done(text) }
                    .keyboardShortcut(.defaultAction)
                    .disabled(PythonText.strip(text).isEmpty)
            }
        }
        .padding(12)
    }
}

/// A screenshot at thumbnail size, decoded small so a long list doesn't hold full images.
private struct Thumbnail: View {
    let url: URL
    @State private var image: NSImage?

    var body: some View {
        Button { NSWorkspace.shared.open(url) } label: {
            Group {
                if let image {
                    Image(nsImage: image).resizable().aspectRatio(contentMode: .fill)
                } else {
                    Rectangle().fill(.quaternary)
                }
            }
            .frame(width: 72, height: 46)
            .clipShape(RoundedRectangle(cornerRadius: 4))
            .overlay(RoundedRectangle(cornerRadius: 4).stroke(.separator))
        }
        .buttonStyle(.plain)
        .help("Open the screenshot")
        .task(id: url) { image = await ThumbnailCache.shared.image(for: url) }
    }
}

final class ThumbnailCache: @unchecked Sendable {
    static let shared = ThumbnailCache()
    private let cache = NSCache<NSURL, NSImage>()

    init() { cache.countLimit = 200 }

    /// When the window closes, so the thumbnails don't stay in memory with it.
    func removeAll() { cache.removeAllObjects() }

    func image(for url: URL) async -> NSImage? {
        if let hit = cache.object(forKey: url as NSURL) { return hit }
        let image = await Task.detached(priority: .utility) { () -> NSImage? in
            guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
            let options: [CFString: Any] = [
                kCGImageSourceCreateThumbnailFromImageAlways: true,
                kCGImageSourceThumbnailMaxPixelSize: 160,
                kCGImageSourceCreateThumbnailWithTransform: true,
            ]
            guard let thumbnail = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else { return nil }
            return NSImage(cgImage: thumbnail, size: NSSize(width: thumbnail.width / 2, height: thumbnail.height / 2))
        }.value
        if let image { cache.setObject(image, forKey: url as NSURL) }
        return image
    }
}
