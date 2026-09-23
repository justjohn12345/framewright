import AppKit
import Combine
import CoreMedia
import SwiftUI
import UniformTypeIdentifiers
import FramewrightEngine

/// Remembers the folder of the last export for the save panel, as a bookmark (security scoped
/// when the app has access to the folder, else a plain one; the save panel runs outside the
/// sandbox and only needs to find the folder) with the path as a last resort.
struct ExportFolderMemory {
    static let bookmarkKey = "exportLastFolderBookmark"
    static let pathKey = "exportLastFolderPath"

    let defaults: UserDefaults

    func save(folder: URL) {
        let bookmark = (try? folder.bookmarkData(options: [.withSecurityScope], includingResourceValuesForKeys: nil,
                                                 relativeTo: nil))
            ?? (try? folder.bookmarkData(options: [.minimalBookmark], includingResourceValuesForKeys: nil,
                                         relativeTo: nil))
        if let bookmark {
            defaults.set(bookmark, forKey: Self.bookmarkKey)
        } else {
            defaults.removeObject(forKey: Self.bookmarkKey)
        }
        defaults.set(folder.path, forKey: Self.pathKey)
    }

    /// The remembered folder, if it still exists.
    func load() -> URL? {
        if let data = defaults.data(forKey: Self.bookmarkKey) {
            var stale = false
            if let url = (try? URL(resolvingBookmarkData: data, options: [.withSecurityScope, .withoutUI],
                                   relativeTo: nil, bookmarkDataIsStale: &stale))
                ?? (try? URL(resolvingBookmarkData: data, options: [.withoutUI], relativeTo: nil,
                             bookmarkDataIsStale: &stale)) {
                return url
            }
        }
        if let path = defaults.string(forKey: Self.pathKey) {
            var isDirectory: ObjCBool = false
            if FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory), isDirectory.boolValue {
                return URL(fileURLWithPath: path, isDirectory: true)
            }
        }
        return nil
    }
}

/// Lets progress through at most once per `minimumInterval` (the first and the final report
/// always pass).
struct ProgressThrottle {
    var minimumInterval: TimeInterval = 0.1
    private(set) var lastPublished: TimeInterval?

    mutating func admit(at now: TimeInterval, final: Bool) -> Bool {
        if final || lastPublished.map({ now - $0 >= minimumInterval }) ?? true {
            lastPublished = now
            return true
        }
        return false
    }
}

/// The Export sheet's logic (File > Export…, Cmd+E): the preset and its options, validation, the
/// hardware/software answer per preset at the output size, the size and duration estimate, the
/// output location, the running export's progress and its outcome.
@MainActor
final class ExportModel: ObservableObject {
    struct Progress: Equatable {
        var fraction: Double
        var framesPerSecond: Double
        var secondsRemaining: Double
        var bytesWritten: UInt64
    }

    /// What the finished export's alert says.
    enum Outcome: Equatable {
        case succeeded(url: URL, message: String)
        case failed(message: String)
    }

    static let qualityChoices: [(title: String, value: Double)] = [
        ("Maximum", 0.95), ("High", 0.8), ("Medium", 0.65), ("Low", 0.45),
    ]
    static let audioBitRates = [128_000, 192_000, 256_000, 320_000]

    private unowned let store: ProjectStore
    let folderMemory: ExportFolderMemory

    @Published var preset: VEExportPreset {
        didSet {
            guard preset != oldValue else { return }
            applyPresetDefaults()
        }
    }

    @Published var container: VEExportContainer {
        didSet {
            if !audioCodecs.contains(audioCodec) { audioCodec = .aac }
            outputContainerChanged()
        }
    }

    @Published var resolution: VEExportResolution { didSet { refreshFormats() } }
    @Published var customWidthText: String { didSet { refreshFormats() } }
    @Published var rateControl: VEExportRateControl
    @Published var quality: Double
    /// Video bit rate in Mb/s, as typed.
    @Published var bitRateText: String
    @Published var audioCodec: VEExportAudioCodec
    @Published var audioBitRate: Int
    @Published private(set) var outputURL: URL?
    /// Why the chosen file was cleared (the container changed): shown until a file is chosen again.
    @Published private(set) var outputNotice: String?
    /// Availability of every preset at the current output size.
    @Published private(set) var formats: [VEExportFormat] = []
    @Published private(set) var progress: Progress?
    @Published private(set) var isExporting = false
    @Published var outcome: Outcome?
    /// Why Export is not possible right now (refusal of the last attempt included).
    @Published private(set) var refusal: String?

    /// Times progress was published (tests: at most 10 Hz).
    private(set) var publishedProgressCount = 0
    private var throttle = ProgressThrottle()
    private var handle: VEExportHandle?
    /// The name (without extension) of the last file chosen, offered again after a container change.
    private var lastChosenName: String?
    private var preferencesForwarding: AnyCancellable?

    /// The clock the progress throttle uses (tests inject their own).
    var now: () -> TimeInterval = { ProcessInfo.processInfo.systemUptime }
    /// Asks where to save: suggested file name, starting folder, content type; nil when cancelled.
    var chooseOutputURL: (String, URL?, UTType) -> URL? = { name, folder, type in
        let panel = NSSavePanel()
        panel.title = "Export"
        panel.nameFieldStringValue = name
        panel.allowedContentTypes = [type]
        panel.canCreateDirectories = true
        panel.isExtensionHidden = false
        if let folder { panel.directoryURL = folder }
        return panel.runModal() == .OK ? panel.url : nil
    }

    /// Shows a file in the Finder.
    var revealInFinder: (URL) -> Void = { NSWorkspace.shared.activateFileViewerSelecting([$0]) }

    init(store: ProjectStore, defaults: UserDefaults = .standard) {
        self.store = store
        folderMemory = ExportFolderMemory(defaults: defaults)
        let initial = VEExportSettings.defaultSettings(for: .h264)
        preset = initial.preset
        container = initial.container
        resolution = initial.resolution
        customWidthText = String(initial.customWidth)
        rateControl = initial.rateControl
        quality = initial.quality
        bitRateText = Self.megabits(initial.videoBitRate)
        audioCodec = initial.audioCodec
        audioBitRate = initial.audioBitRate
        // Durations follow the duration display preference while the sheet is open.
        preferencesForwarding = store.preferences.objectWillChange.sink { [weak self] _ in
            self?.objectWillChange.send()
        }
        refreshFormats()
    }

    // MARK: Options

    var presets: [VEExportPreset] { [.h264, .hevc, .hevc10Bit, .proRes422, .av1] }
    var containers: [VEExportContainer] {
        VEExportSettings.containers(for: preset).compactMap { VEExportContainer(rawValue: $0.intValue) }
    }

    var audioCodecs: [VEExportAudioCodec] {
        VEExportSettings.audioCodecs(for: container).compactMap { VEExportAudioCodec(rawValue: $0.intValue) }
    }

    var isProRes: Bool { preset == .proRes422 }

    static func name(of preset: VEExportPreset) -> String { VEExportSettings.name(for: preset) }
    static func name(of container: VEExportContainer) -> String { VEExportSettings.name(for: container) }
    static func name(of codec: VEExportAudioCodec) -> String {
        switch codec {
        case .noAudio: return "None"
        case .aac: return "AAC"
        case .pcm: return "PCM (16-bit)"
        @unknown default: return "?"
        }
    }

    static func name(of resolution: VEExportResolution) -> String {
        switch resolution {
        case .sequence: return "Sequence size"
        case .hd1080: return "1080p"
        case .hd720: return "720p"
        case .custom: return "Custom width"
        @unknown default: return "?"
        }
    }

    static func megabits(_ bitsPerSecond: Int64) -> String {
        let value = Double(bitsPerSecond) / 1_000_000
        return value == value.rounded() ? String(format: "%.0f", value) : String(format: "%.1f", value)
    }

    /// The format entry of `preset` at the current size (nil until probed).
    func format(for preset: VEExportPreset) -> VEExportFormat? {
        formats.first { $0.preset == preset }
    }

    /// "Hardware" / "Software" for the picker, or nil while unknown or unavailable.
    func badge(for preset: VEExportPreset) -> String? {
        guard let format = format(for: preset), format.available else { return nil }
        return format.hardware ? "Hardware" : "Software"
    }

    // MARK: Derived

    /// The settings as typed, or nil when a field is not a number.
    var settings: VEExportSettings? {
        let width = Int(customWidthText.trimmingCharacters(in: .whitespaces))
        if resolution == .custom, width == nil { return nil }
        let rate = Double(bitRateText.trimmingCharacters(in: .whitespaces).replacingOccurrences(of: ",", with: "."))
        if rateControl == .bitRate, !isProRes, rate == nil { return nil }
        return VEExportSettings(preset: preset, container: container, resolution: resolution,
                                customWidth: width ?? 1280, rateControl: rateControl, quality: quality,
                                videoBitRate: Int64(((rate ?? 0) * 1_000_000).rounded()), audioCodec: audioCodec,
                                audioBitRate: audioBitRate)
    }

    var outputSize: CGSize {
        guard let settings else { return .zero }
        return store.engine.exportSize(for: settings)
    }

    var sequenceFrames: Int64 { store.frames(store.sequence.duration) }

    /// Why the current settings cannot be exported, or nil.
    var validationMessage: String? {
        if resolution == .custom, Int(customWidthText.trimmingCharacters(in: .whitespaces)) == nil {
            return "Type the width in pixels."
        }
        guard let settings else { return "Type the bit rate in Mb/s." }
        if let message = settings.validationMessage { return message }
        if outputSize.width < 2 { return "The frame size is not usable." }
        if let format = format(for: preset), !format.available { return format.unavailableReason }
        if sequenceFrames <= 0 { return "The sequence is empty: there is nothing to export." }
        return nil
    }

    var sizeText: String {
        let size = outputSize
        return size.width > 0 ? "\(Int(size.width))×\(Int(size.height))" : "—"
    }

    var durationText: String { store.durationString(frames: sequenceFrames) }

    var estimatedSizeText: String {
        guard let settings else { return "—" }
        let bytes = store.engine.estimatedFileSize(for: settings)
        guard bytes > 0 else { return "—" }
        return "≈ " + ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
    }

    /// Why the Export button is disabled (nil when it is enabled).
    var exportDisabledReason: String? {
        if isExporting { return "An export is running." }
        if store.isGestureActive { return "Finish the current drag first." }
        if let validationMessage { return validationMessage }
        if outputURL == nil { return outputNotice ?? "Choose where to save the file." }
        return nil
    }

    var canExport: Bool { exportDisabledReason == nil }

    var suggestedFileName: String {
        let base = store.projectName.isEmpty ? "Export" : store.projectName
        return base + "." + VEExportSettings.fileExtension(for: container)
    }

    var contentType: UTType {
        switch container {
        case .mov: return .quickTimeMovie
        case .mkv: return UTType(filenameExtension: "mkv") ?? .movie
        default: return .mpeg4Movie
        }
    }

    // MARK: Actions

    private func applyPresetDefaults() {
        let defaults = VEExportSettings.defaultSettings(for: preset)
        if !containers.contains(container) { container = defaults.container }
        if defaults.audioCodec == .pcm || !audioCodecs.contains(audioCodec) {
            audioCodec = audioCodecs.contains(defaults.audioCodec) ? defaults.audioCodec : .aac
        }
        bitRateText = Self.megabits(defaults.videoBitRate)
        refreshFormats()
    }

    /// Asks the engine which presets it can export at the current size.
    func refreshFormats() {
        let size = outputSize
        guard size.width >= 2 else {
            formats = []
            return
        }
        store.engine.exportFormats(forWidth: Int(size.width), height: Int(size.height)) { [weak self] formats in
            guard let self, self.outputSize == size else { return }
            self.formats = formats
        }
    }

    /// The save panel, starting in the last export's folder.
    func chooseOutput() {
        let start = outputURL?.deletingLastPathComponent() ?? folderMemory.load()
        let name = (outputURL?.deletingPathExtension().lastPathComponent ?? lastChosenName)
            .map { $0 + "." + VEExportSettings.fileExtension(for: container) } ?? suggestedFileName
        guard let url = chooseOutputURL(name, start, contentType) else { return }
        setOutputURL(url)
    }

    func setOutputURL(_ url: URL) {
        outputURL = url
        outputNotice = nil
        lastChosenName = url.deletingPathExtension().lastPathComponent
        refusal = nil
        folderMemory.save(folder: url.deletingLastPathComponent())
    }

    /// A container change after a file was chosen: the save panel granted access to exactly that
    /// file (the sandbox would refuse the same name with another extension, and outside it a
    /// renamed file could replace another one without the Replace question), and its extension
    /// names the container. So the choice is cleared and the file has to be chosen again (the
    /// panel then offers the same name and folder with the new extension).
    private func outputContainerChanged() {
        guard let url = outputURL else { return }
        let ext = VEExportSettings.fileExtension(for: container)
        guard url.pathExtension.lowercased() != ext else { return }
        outputURL = nil
        outputNotice = "The container is now \(Self.name(of: container)): choose the file again (.\(ext))."
    }

    /// Starts the export. Returns false (with `refusal` set) when the engine refused it.
    @discardableResult
    func startExport() -> Bool {
        if let reason = exportDisabledReason {
            refusal = reason
            return false
        }
        guard let settings, let url = outputURL else { return false }
        throttle = ProgressThrottle()
        do {
            handle = try store.engine.beginExport(with: settings, outputURL: url, progress: { [weak self] report in
                self?.receive(report)
            }, completion: { [weak self] summary, error in
                self?.finish(summary: summary, error: error)
            })
        } catch {
            refusal = error.localizedDescription
            return false
        }
        refusal = nil
        isExporting = true
        progress = Progress(fraction: 0, framesPerSecond: 0, secondsRemaining: -1, bytesWritten: 0)
        store.exportStateChanged()
        store.statusMessage = "Exporting “\(url.lastPathComponent)”…"
        return true
    }

    func cancelExport() {
        handle?.cancel()
    }

    /// Publishes a progress report, at most 10 times a second.
    func receive(_ report: VEExportProgress) {
        receive(Progress(fraction: report.fractionCompleted, framesPerSecond: report.framesPerSecond,
                         secondsRemaining: report.estimatedSecondsRemaining, bytesWritten: report.bytesWritten),
                final: report.totalFrames > 0 && report.framesCompleted >= report.totalFrames)
    }

    func receive(_ report: Progress, final: Bool) {
        guard isExporting, throttle.admit(at: now(), final: final) else { return }
        publishedProgressCount += 1
        progress = report
    }

    func finish(summary: VEExportSummary?, error: Error?) {
        isExporting = false
        handle = nil
        progress = nil
        store.exportStateChanged()
        if let summary {
            let size = ByteCountFormatter.string(fromByteCount: Int64(summary.fileSize), countStyle: .file)
            let encoder = summary.hardwareAccelerated ? "hardware" : "software"
            let duration = store.durationString(frames: store.frames(summary.duration))
            let message = "\(summary.outputURL.lastPathComponent): \(duration), \(summary.width)×\(summary.height), "
                + "\(size), \(summary.encoderName.isEmpty ? encoder : summary.encoderName), "
                + String(format: "exported in %.1f s (%.0f fps).", summary.wallSeconds,
                         summary.averageFramesPerSecond)
            store.statusMessage = "Exported " + message
            outcome = .succeeded(url: summary.outputURL, message: message)
        } else if let error = error as NSError?, error.domain == VEEngineErrorDomain,
                  error.code == VEEngineError.Code.exportCancelled.rawValue {
            store.statusMessage = "Export cancelled."
        } else {
            let message = error?.localizedDescription ?? "The export failed."
            store.statusMessage = "Export failed: " + message
            outcome = .failed(message: message)
        }
    }

    func reveal() {
        if case let .succeeded(url, _) = outcome { revealInFinder(url) }
    }

    /// Closes the sheet (not while exporting).
    func close() {
        guard !isExporting else { return }
        store.exportModel = nil
    }
}

/// File > Export… (Cmd+E).
struct ExportSheet: View {
    @ObservedObject var model: ExportModel

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Export Sequence").font(.headline)
            Form {
                Picker("Format", selection: $model.preset) {
                    ForEach(model.presets, id: \.self) { preset in
                        Text(Self.presetLabel(model, preset)).tag(preset)
                    }
                }
                .accessibilityIdentifier("ExportPreset")
                if let format = model.format(for: model.preset) {
                    Label(format.available ? format.encoderDescription : format.unavailableReason,
                          systemImage: format.hardware ? "cpu" : "gearshape")
                        .font(.callout)
                        .foregroundStyle(format.available ? Color.secondary : Color.orange)
                }
                Picker("Container", selection: $model.container) {
                    ForEach(model.containers, id: \.self) { Text(ExportModel.name(of: $0)).tag($0) }
                }
                Picker("Resolution", selection: $model.resolution) {
                    ForEach([VEExportResolution.sequence, .hd1080, .hd720, .custom], id: \.self) {
                        Text(ExportModel.name(of: $0)).tag($0)
                    }
                }
                if model.resolution == .custom {
                    TextField("Width (pixels)", text: $model.customWidthText)
                        .frame(width: 160)
                }
                LabeledContent("Frame size", value: model.sizeText)
                if !model.isProRes {
                    Picker("Rate control", selection: $model.rateControl) {
                        Text("Quality").tag(VEExportRateControl.quality)
                        Text("Bit rate").tag(VEExportRateControl.bitRate)
                    }
                    .pickerStyle(.segmented)
                    if model.rateControl == .quality {
                        Picker("Quality", selection: $model.quality) {
                            ForEach(ExportModel.qualityChoices, id: \.value) { Text($0.title).tag($0.value) }
                        }
                    } else {
                        HStack {
                            TextField("Bit rate", text: $model.bitRateText).frame(width: 100)
                            Text("Mb/s").foregroundStyle(.secondary)
                        }
                    }
                }
                Picker("Audio", selection: $model.audioCodec) {
                    ForEach(model.audioCodecs, id: \.self) { Text(ExportModel.name(of: $0)).tag($0) }
                }
                if model.audioCodec == .aac {
                    Picker("Audio bit rate", selection: $model.audioBitRate) {
                        ForEach(ExportModel.audioBitRates, id: \.self) { Text("\($0 / 1000) kb/s").tag($0) }
                    }
                }
                LabeledContent("Duration", value: model.durationText)
                LabeledContent("Estimated size", value: model.estimatedSizeText)
                HStack {
                    Text(model.outputURL?.path ?? model.outputNotice ?? "No file chosen")
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .foregroundStyle(model.outputURL == nil ? .secondary : .primary)
                        .help(model.outputURL?.path ?? "")
                    Spacer()
                    Button("Choose…") { model.chooseOutput() }
                        .disabled(model.isExporting)
                }
            }
            .disabled(model.isExporting)
            if let progress = model.progress {
                VStack(alignment: .leading, spacing: 4) {
                    ProgressView(value: progress.fraction)
                    Text(Self.progressText(progress))
                        .font(.caption)
                        .monospacedDigit()
                        .foregroundStyle(.secondary)
                }
            }
            if let message = model.refusal ?? (model.isExporting ? nil : model.validationMessage) {
                Label(message, systemImage: "exclamationmark.triangle.fill")
                    .foregroundStyle(.orange)
                    .font(.callout)
                    .fixedSize(horizontal: false, vertical: true)
            }
            HStack {
                Spacer()
                if model.isExporting {
                    Button("Cancel Export", role: .cancel) { model.cancelExport() }
                        .keyboardShortcut(.cancelAction)
                } else {
                    Button("Close", role: .cancel) { model.close() }
                        .keyboardShortcut(.cancelAction)
                    Button("Export") { model.startExport() }
                        .keyboardShortcut(.defaultAction)
                        .disabled(!model.canExport)
                        .help(model.exportDisabledReason ?? "")
                }
            }
        }
        .padding(20)
        .frame(width: 480)
        .alert(Self.alertTitle(model.outcome), isPresented: Binding(get: { model.outcome != nil },
                                                                    set: { if !$0 { model.outcome = nil } })) {
            if case .succeeded = model.outcome {
                Button("Reveal in Finder") {
                    model.reveal()
                    model.outcome = nil
                    model.close()
                }
                Button("OK", role: .cancel) {
                    model.outcome = nil
                    model.close()
                }
            } else {
                Button("OK", role: .cancel) { model.outcome = nil }
            }
        } message: {
            switch model.outcome {
            case let .succeeded(_, message): Text(message)
            case let .failed(message): Text(message)
            case nil: Text("")
            }
        }
    }

    static func presetLabel(_ model: ExportModel, _ preset: VEExportPreset) -> String {
        let name = ExportModel.name(of: preset)
        if let badge = model.badge(for: preset) { return "\(name) — \(badge)" }
        if let format = model.format(for: preset), !format.available { return "\(name) — unavailable" }
        return name
    }

    static func progressText(_ progress: ExportModel.Progress) -> String {
        var parts = [String(format: "%.0f %%", progress.fraction * 100)]
        if progress.framesPerSecond > 0 { parts.append(String(format: "%.0f fps", progress.framesPerSecond)) }
        if progress.secondsRemaining >= 0 {
            let seconds = Int(progress.secondsRemaining.rounded(.up))
            parts.append(seconds >= 60 ? "\(seconds / 60) min \(seconds % 60) s left" : "\(seconds) s left")
        }
        if progress.bytesWritten > 0 {
            parts.append(ByteCountFormatter.string(fromByteCount: Int64(progress.bytesWritten), countStyle: .file))
        }
        return parts.joined(separator: " · ")
    }

    static func alertTitle(_ outcome: ExportModel.Outcome?) -> String {
        switch outcome {
        case .succeeded: return "Export finished"
        case .failed: return "The export failed"
        case nil: return ""
        }
    }
}
