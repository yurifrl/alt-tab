import Foundation

/// A config file that cannot be read or validated. `description` is the one
/// sentence the app and its CLI modes show; it names the file, the line and
/// the problem.
struct ConfigError: Error, CustomStringConvertible {
    let file: String        // absolute path
    let line: Int?          // 1-based, nil when the file as a whole is at fault
    let path: String?       // e.g. "panel.maxRows"
    let problem: String     // one sentence, names accepted values

    var description: String {
        var text = "open \(file):"
        if let line { text += " line \(line)," }
        if let path { text += " \(path):" }
        return text + " \(problem)"
    }
}

/// The settings database: one YAML file, decoded once at boot, saved ~200 ms
/// after the last mutation and synchronously on quit.
enum ConfigStore {
    /// `ALT_TAB_CONFIG` (demos and tests) wins over the user's file.
    static var file: URL {
        let env = ProcessInfo.processInfo.environment["ALT_TAB_CONFIG"] ?? ""
        if !env.isEmpty {
            return URL(fileURLWithPath: (env as NSString).expandingTildeInPath).standardizedFileURL
        }
        return FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".config/alt-tab/config.yaml")
    }

    // MARK: - Loading

    /// Absent file → import today's defaults, write immediately. Present file
    /// → decode and validate; a broken file throws and is never rewritten.
    /// Idempotent: the file is read once per process.
    static func load() throws {
        lock.lock()
        let loaded = document != nil
        lock.unlock()
        if loaded { return }

        let url = file
        guard FileManager.default.fileExists(atPath: url.path) else {
            let values = DefaultsImporter.importFromUserDefaults()
            lock.lock()
            document = values
            dirty = true
            lock.unlock()
            _ = writeDocument()
            return
        }

        let data: Data
        do {
            data = try Data(contentsOf: url)
        } catch {
            throw ConfigError(file: url.path, line: nil, path: nil,
                              problem: "cannot be read: \(error.localizedDescription)")
        }
        guard let text = String(data: data, encoding: .utf8) else {
            throw ConfigError(file: url.path, line: nil, path: nil,
                              problem: "is not valid UTF-8")
        }
        let values = try ConfigCodec.decode(text, file: url.path)

        lock.lock()
        document = values
        dirty = false
        lock.unlock()
    }

    /// The live document. Reading before `load()` loads on demand; a broken
    /// file at that point is fatal (boot loads first and shows the alert).
    static var values: Config.Values {
        get {
            ensureLoaded()
            lock.lock()
            defer { lock.unlock() }
            return document ?? Config.Values()
        }
        set {
            ensureLoaded()
            lock.lock()
            document = newValue
            dirty = true
            lock.unlock()
            scheduleSave()
        }
    }

    /// Read-modify-write one setting; the debounced save follows.
    static func mutate(_ body: (inout Config.Values) -> Void) {
        ensureLoaded()
        lock.lock()
        var doc = document ?? Config.Values()
        body(&doc)
        document = doc
        dirty = true
        lock.unlock()
        scheduleSave()
    }

    /// Synchronous write if dirty; a no-op otherwise. Safe to call twice.
    static func flush() {
        _ = writeDocument()
    }

    // MARK: - Saving

    private static let lock = NSLock()
    private static let saves = DispatchQueue(label: "at.config.saves")
    private static var document: Config.Values?
    private static var dirty = false
    private static var savePending = false

    private static func ensureLoaded() {
        lock.lock()
        let loaded = document != nil
        lock.unlock()
        if loaded { return }
        do {
            try load()
        } catch {
            // Boot owns the alert; reaching here means a setting was read
            // before the file was loaded, so report the way CLI modes do.
            FileHandle.standardError.write(Data("\(error)\n".utf8))
            exit(1)
        }
    }

    private static func scheduleSave() {
        lock.lock()
        if savePending {
            lock.unlock()
            return
        }
        savePending = true
        lock.unlock()
        saves.asyncAfter(deadline: .now() + 0.2) { saveOnce() }
    }

    /// A write that fails keeps the document dirty and is retried on the next
    /// save or flush; it never crashes or alerts.
    private static func saveOnce() {
        let saved = writeDocument()
        lock.lock()
        savePending = false
        let again = saved && dirty
        lock.unlock()
        if again { scheduleSave() }
    }

    /// Returns true when nothing is left dirty.
    @discardableResult
    private static func writeDocument() -> Bool {
        lock.lock()
        guard dirty, let doc = document else {
            lock.unlock()
            return true
        }
        dirty = false     // restored below when the write fails
        lock.unlock()

        let url = file
        do {
            try write(ConfigCodec.encode(doc), to: url)
            return true
        } catch {
            lock.lock()
            dirty = true
            lock.unlock()
            FileHandle.standardError.write(
                Data("alt-tab: cannot save \(url.path): \(error.localizedDescription)\n".utf8))
            return false
        }
    }

    /// Atomic: temp file in the same directory, mode 0600, directory 0700,
    /// then rename over the target.
    private static func write(_ text: String, to url: URL) throws {
        let fm = FileManager.default
        let dir = url.deletingLastPathComponent()
        if !fm.fileExists(atPath: dir.path) {
            try fm.createDirectory(at: dir, withIntermediateDirectories: true,
                                   attributes: [.posixPermissions: 0o700])
        }
        let temp = dir.appendingPathComponent(".\(url.lastPathComponent).\(UUID().uuidString).tmp")
        do {
            try Data(text.utf8).write(to: temp)
            try fm.setAttributes([.posixPermissions: 0o600], ofItemAtPath: temp.path)
        } catch {
            try? fm.removeItem(at: temp)
            throw error
        }
        guard rename(temp.path, url.path) == 0 else {
            let code = errno
            try? fm.removeItem(at: temp)
            throw NSError(domain: NSPOSIXErrorDomain, code: Int(code),
                          userInfo: [NSLocalizedDescriptionKey: String(cString: strerror(code))])
        }
    }
}
