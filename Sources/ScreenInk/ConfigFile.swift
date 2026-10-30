import Foundation
import ScreenInkCore

/// Keeps `~/.ScreenInk/config.yml` and the running app in step, in both directions.
///
/// A file that doesn't parse is reported and left alone: the app carries on with its last good
/// settings and writes nothing until the file is fixed, so a typo never costs anyone their edits.
@MainActor
final class ConfigFile {
    static let defaultURL = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent(".ScreenInk/config.yml")

    let url: URL
    /// What's wrong with the file on disk, if anything.
    private(set) var problem: String?
    /// The file was edited outside the app, and these are its new settings.
    var onExternalChange: ((Settings) -> Void)?
    /// The file was edited outside the app, and it doesn't parse. Called once per distinct problem.
    var onProblem: ((String) -> Void)?

    /// The settings the file holds, so saving the same ones again doesn't rewrite it and drop its comments.
    private var settingsOnDisk: Settings?
    private var textOnDisk: String?
    private var pending: Settings?
    private var saveWork: DispatchWorkItem?
    private var reloadWork: DispatchWorkItem?
    private var directorySource: DispatchSourceFileSystemObject?
    private var fileSource: DispatchSourceFileSystemObject?

    init(url: URL = ConfigFile.defaultURL) {
        self.url = url
    }

    /// Reads the file, creating it from `initial` if it doesn't exist yet, and starts watching it.
    /// Returns the settings to run with.
    func load(initial: @autoclosure () -> Settings) -> Settings {
        var settings: Settings
        if let text = read() {
            textOnDisk = text
            do {
                settings = try Settings(yaml: text)
                settingsOnDisk = settings
            } catch {
                problem = "\(error)"
                settings = Settings()
            }
        } else {
            settings = initial()
            write(settings)
        }
        watch()
        return settings
    }

    /// Saves shortly after the last change, so dragging a slider doesn't write a file per step.
    func save(_ settings: Settings) {
        pending = settings
        guard saveWork == nil else { return }
        let work = DispatchWorkItem { [weak self] in
            MainActor.assumeIsolated { self?.flush() }
        }
        saveWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3, execute: work)
    }

    /// Writes any pending change now (at quit).
    func flush() {
        saveWork?.cancel()
        saveWork = nil
        guard let settings = pending else { return }
        pending = nil
        // An edit we haven't seen yet wins over an in-app change, which would otherwise overwrite it.
        guard read() == textOnDisk else {
            reload()
            return
        }
        guard problem == nil, settings != settingsOnDisk else { return }
        write(settings)
    }

    /// Picks up the file's current contents if they aren't what we last read or wrote.
    func reload() {
        guard let text = read(), text != textOnDisk else { return }
        textOnDisk = text
        pending = nil
        do {
            let settings = try Settings(yaml: text)
            problem = nil
            settingsOnDisk = settings
            onExternalChange?(settings)
        } catch {
            let message = "\(error)"
            let isNew = message != problem
            problem = message
            if isNew { onProblem?(message) }
        }
    }

    private func read() -> String? {
        try? String(contentsOf: url, encoding: .utf8)
    }

    private func write(_ settings: Settings) {
        let text = settings.yaml
        do {
            try FileManager.default.createDirectory(
                at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try text.write(to: url, atomically: true, encoding: .utf8)
            textOnDisk = text
            settingsOnDisk = settings
            problem = nil
        } catch {
            problem = "Couldn't write \(url.path): \(error.localizedDescription)"
        }
    }

    // MARK: Watching

    /// Atomic saves replace the file, which only the directory sees; in-place writes
    /// only change the file. So both are watched, and the file reopened after each event.
    private func watch() {
        let directory = url.deletingLastPathComponent()
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        directorySource = makeSource(path: directory.path, events: .write)
        watchFile()
    }

    private func watchFile() {
        fileSource?.cancel()
        fileSource = makeSource(path: url.path, events: [.write, .extend, .delete, .rename])
    }

    private func makeSource(path: String, events: DispatchSource.FileSystemEvent) -> DispatchSourceFileSystemObject? {
        let descriptor = open(path, O_EVTONLY)
        guard descriptor >= 0 else { return nil }
        let source = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: descriptor, eventMask: events, queue: .main)
        source.setEventHandler { [weak self] in
            MainActor.assumeIsolated { self?.fileSystemDidChange() }
        }
        source.setCancelHandler { close(descriptor) }
        source.resume()
        return source
    }

    private func fileSystemDidChange() {
        reloadWork?.cancel()
        let work = DispatchWorkItem { [weak self] in
            MainActor.assumeIsolated {
                self?.watchFile()
                self?.reload()
            }
        }
        reloadWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1, execute: work)
    }
}

extension Settings {
    /// What earlier versions kept in `UserDefaults`, used once to create the config file.
    static func legacy(from defaults: UserDefaults) -> Settings {
        var settings = Settings()
        if let tool = defaults.string(forKey: "Tool").flatMap(ToolKind.init(rawValue:)) { settings.tool = tool }
        settings.colorIndex = min(max(defaults.integer(forKey: "ColorIndex"), 0), RGBA.palette.count - 1)
        let width = defaults.double(forKey: "Width")
        if width > 0 { settings.width = min(max(width, widthRange.lowerBound), widthRange.upperBound) }
        let fade = defaults.double(forKey: "AutoFadeSeconds")
        settings.autoFadeSeconds = fade > 0 ? fade : nil
        settings.dimLevel = min(max(defaults.double(forKey: "DimLevel"), dimRange.lowerBound), dimRange.upperBound)
        settings.sideButtonsEnabled = defaults.bool(forKey: "SideButtonsEnabled")
        if let origin = defaults.string(forKey: "PaletteOrigin") {
            settings.paletteOrigin = NSPointFromString(origin)
        }
        return settings
    }
}
