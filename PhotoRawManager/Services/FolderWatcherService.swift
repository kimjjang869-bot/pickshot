import Foundation

/// Watches a folder for file system changes using DispatchSource (kqueue-based).
/// When new files appear in the watched folder, notifies via callback so the
/// photo list can be refreshed.
///
/// Uses a debounce mechanism to avoid excessive reloads when multiple files
/// are added simultaneously (e.g., during a copy operation).
class FolderWatcherService {
    private var source: DispatchSourceFileSystemObject?
    private var fileDescriptor: Int32 = -1
    private var debounceWorkItem: DispatchWorkItem?
    private var watchedURL: URL?
    private var knownFiles: Set<String> = []

    /// Debounce interval in seconds. File system events within this window
    /// are coalesced into a single callback.
    var debounceInterval: TimeInterval = 1.5

    /// Called on the main queue when new files are detected.
    /// The Set contains URLs of newly added files.
    var onNewFilesDetected: ((Set<URL>) -> Void)?

    /// Start watching the given folder URL for changes.
    /// Captures the current file list as baseline.
    func startWatching(folder: URL) {
        stopWatching()

        watchedURL = folder
        knownFiles = currentFileNames(in: folder)

        let fd = open(folder.path, O_EVTONLY)
        guard fd >= 0 else {
            print("[FolderWatcher] Failed to open folder for watching: \(folder.path)")
            return
        }
        fileDescriptor = fd

        let source = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: fd,
            eventMask: [.write, .rename, .link],
            queue: DispatchQueue.global(qos: .utility)
        )

        source.setEventHandler { [weak self] in
            self?.handleFileSystemEvent()
        }

        source.setCancelHandler { [weak self] in
            if let fd = self?.fileDescriptor, fd >= 0 {
                close(fd)
                self?.fileDescriptor = -1
            }
        }

        self.source = source
        source.resume()
    }

    /// Stop watching the current folder.
    func stopWatching() {
        debounceWorkItem?.cancel()
        debounceWorkItem = nil

        if let source = source {
            source.cancel()
            self.source = nil
        } else if fileDescriptor >= 0 {
            close(fileDescriptor)
            fileDescriptor = -1
        }

        watchedURL = nil
        knownFiles.removeAll()
    }

    deinit {
        stopWatching()
    }

    // MARK: - Private

    private func handleFileSystemEvent() {
        // Debounce: cancel any pending check and schedule a new one
        debounceWorkItem?.cancel()

        let workItem = DispatchWorkItem { [weak self] in
            self?.checkForNewFiles()
        }
        debounceWorkItem = workItem

        DispatchQueue.global(qos: .utility).asyncAfter(
            deadline: .now() + debounceInterval,
            execute: workItem
        )
    }

    private func checkForNewFiles() {
        guard let folder = watchedURL else { return }

        let currentFiles = currentFileNames(in: folder)
        let newFileNames = currentFiles.subtracting(knownFiles)

        guard !newFileNames.isEmpty else { return }

        // Resolve new file names to URLs
        let fm = FileManager.default
        var newURLs = Set<URL>()

        if let enumerator = fm.enumerator(
            at: folder,
            includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsHiddenFiles, .skipsSubdirectoryDescendants]
        ) {
            while let fileURL = enumerator.nextObject() as? URL {
                let name = fileURL.lastPathComponent
                if newFileNames.contains(name) {
                    newURLs.insert(fileURL)
                }
            }
        }

        // Also check subdirectories for new files
        if let enumerator = fm.enumerator(
            at: folder,
            includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsHiddenFiles]
        ) {
            while let fileURL = enumerator.nextObject() as? URL {
                let name = fileURL.lastPathComponent
                if newFileNames.contains(name) {
                    newURLs.insert(fileURL)
                }
            }
        }

        // Update known files
        knownFiles = currentFiles

        guard !newURLs.isEmpty else { return }

        DispatchQueue.main.async { [weak self] in
            self?.onNewFilesDetected?(newURLs)
        }
    }

    private func currentFileNames(in folder: URL) -> Set<String> {
        let fm = FileManager.default
        var names = Set<String>()

        guard let enumerator = fm.enumerator(
            at: folder,
            includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsHiddenFiles]
        ) else {
            return names
        }

        while let fileURL = enumerator.nextObject() as? URL {
            guard let rv = try? fileURL.resourceValues(forKeys: [.isRegularFileKey]),
                  rv.isRegularFile == true else { continue }
            names.insert(fileURL.lastPathComponent)
        }

        return names
    }
}
