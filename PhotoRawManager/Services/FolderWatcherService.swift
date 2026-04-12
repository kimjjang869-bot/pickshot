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
    private let stateLock = NSLock()  // knownFiles/knownSubfolders 스레드 안전

    /// Debounce interval in seconds. File system events within this window
    /// are coalesced into a single callback.
    var debounceInterval: TimeInterval = 1.5

    /// Called on the main queue when new files are detected.
    var onNewFilesDetected: ((Set<URL>) -> Void)?

    /// Called on the main queue when folder structure changes (new/deleted subfolder).
    var onFolderStructureChanged: (() -> Void)?

    /// Start watching the given folder URL for changes.
    /// Captures the current file list as baseline.
    func startWatching(folder: URL) {
        stopWatching()

        watchedURL = folder
        stateLock.lock()
        knownFiles = currentFileNames(in: folder)
        knownSubfolders = currentSubfolderNames(in: folder)
        stateLock.unlock()

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

        // 폴더 구조 변경 감지 (새 폴더 생성/삭제)
        let currentFolders = currentSubfolderNames(in: folder)
        stateLock.lock()
        let folderChanged = currentFolders != knownSubfolders
        if folderChanged {
            let added = currentFolders.subtracting(knownSubfolders)
            let removed = knownSubfolders.subtracting(currentFolders)
            if !added.isEmpty || !removed.isEmpty {
                knownSubfolders = currentFolders
                stateLock.unlock()
                DispatchQueue.main.async { [weak self] in
                    self?.onFolderStructureChanged?()
                }
            } else {
                stateLock.unlock()
            }
        } else {
            stateLock.unlock()
        }

        let currentFiles = currentFileNames(in: folder)

        stateLock.lock()
        // 파일 수가 같으면 무시 (메타데이터 변경은 리로드 불필요)
        guard currentFiles.count != knownFiles.count || currentFiles != knownFiles else { stateLock.unlock(); return }

        let newFileNames = currentFiles.subtracting(knownFiles)
        let deletedFiles = knownFiles.subtracting(currentFiles)

        // 실제 추가/삭제가 있을 때만 처리
        if !deletedFiles.isEmpty {
            knownFiles = currentFiles
            stateLock.unlock()
            DispatchQueue.main.async { [weak self] in
                self?.onFolderStructureChanged?()
            }
            if newFileNames.isEmpty { return }
        } else {
            stateLock.unlock()
        }

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
        stateLock.lock()
        knownFiles = currentFiles
        stateLock.unlock()

        guard !newURLs.isEmpty else { return }

        DispatchQueue.main.async { [weak self] in
            self?.onNewFilesDetected?(newURLs)
        }
    }

    private var knownSubfolders: Set<String> = []

    private func currentFileNames(in folder: URL) -> Set<String> {
        let fm = FileManager.default
        var names = Set<String>()

        guard let items = try? fm.contentsOfDirectory(at: folder, includingPropertiesForKeys: [.isRegularFileKey, .isDirectoryKey], options: [.skipsHiddenFiles]) else {
            return names
        }

        for item in items {
            if let rv = try? item.resourceValues(forKeys: [.isRegularFileKey]),
               rv.isRegularFile == true {
                names.insert(item.lastPathComponent)
            }
        }

        return names
    }

    private func currentSubfolderNames(in folder: URL) -> Set<String> {
        let fm = FileManager.default
        guard let items = try? fm.contentsOfDirectory(at: folder, includingPropertiesForKeys: [.isDirectoryKey], options: [.skipsHiddenFiles]) else {
            return []
        }
        var dirs = Set<String>()
        for item in items {
            if (try? item.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true {
                dirs.insert(item.lastPathComponent)
            }
        }
        return dirs
    }
}
