import Foundation
import AppKit
import Darwin

struct CopyResult {
    var totalFiles: Int = 0
    var copiedJPG: Int = 0
    var copiedRAW: Int = 0
    var copiedXMP: Int = 0
    var failedFiles: [String] = []
    var verified: Bool = false
    var skipped: Int = 0
}

/// 중복 파일 처리 모드
enum DuplicateHandling {
    case overwrite   // 덮어쓰기
    case rename      // 이름 변경 (_1, _2...)
    case skip        // 건너뛰기
}

struct FileCopyService {

    // MARK: - 중복 검사 (폴더 내보내기용)

    static func findDuplicates(
        photos: [PhotoItem],
        destinationURL: URL,
        jpgFolderName: String = "JPG",
        rawFolderName: String = "RAW",
        singleFolder: Bool = false
    ) -> [String] {
        let fm = FileManager.default
        let jpgName = jpgFolderName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "JPG" : jpgFolderName.trimmingCharacters(in: .whitespacesAndNewlines)
        let rawName = rawFolderName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "RAW" : rawFolderName.trimmingCharacters(in: .whitespacesAndNewlines)
        let jpgFolder = singleFolder ? destinationURL : destinationURL.appendingPathComponent(jpgName)
        let rawFolder = singleFolder ? destinationURL : destinationURL.appendingPathComponent(rawName)

        var duplicates: [String] = []
        for photo in photos {
            if !photo.isRawOnly {
                let jpgDest = jpgFolder.appendingPathComponent(photo.jpgURL.lastPathComponent)
                if fm.fileExists(atPath: jpgDest.path) {
                    duplicates.append(photo.jpgURL.lastPathComponent)
                }
            }
            if let rawURL = photo.rawURL {
                let rawDest = rawFolder.appendingPathComponent(rawURL.lastPathComponent)
                if fm.fileExists(atPath: rawDest.path) {
                    duplicates.append(rawURL.lastPathComponent)
                }
            }
        }
        return duplicates
    }

    // MARK: - 중복 검사 (Lightroom용)

    static func findDuplicatesForLightroom(
        photos: [PhotoItem],
        destinationURL: URL
    ) -> [String] {
        let fm = FileManager.default
        var duplicates: [String] = []
        for photo in photos {
            let sourceURL = photo.rawURL ?? photo.jpgURL
            let destFile = destinationURL.appendingPathComponent(sourceURL.lastPathComponent)
            if fm.fileExists(atPath: destFile.path) {
                duplicates.append(sourceURL.lastPathComponent)
            }
        }
        return duplicates
    }

    /// 중복 파일 이름에 접미사 추가 (_1, _2, ...)
    private static func uniqueURL(for url: URL) -> URL {
        let fm = FileManager.default
        guard fm.fileExists(atPath: url.path) else { return url }
        let dir = url.deletingLastPathComponent()
        let baseName = url.deletingPathExtension().lastPathComponent
        let ext = url.pathExtension
        var counter = 1
        while true {
            let newName = "\(baseName)_\(counter).\(ext)"
            let newURL = dir.appendingPathComponent(newName)
            if !fm.fileExists(atPath: newURL.path) { return newURL }
            counter += 1
        }
    }

    // MARK: - 고속 복사 (Finder보다 빠르게)

    /// APFS 클론 → copyfile() C API → FileManager fallback
    private static func fastCopy(from source: URL, to dest: URL) throws {
        let src = source.path
        let dst = dest.path

        // 1차: APFS 클론 시도 (같은 볼륨이면 즉시, ~0ms)
        let cloneResult = src.withCString { srcPtr in
            dst.withCString { dstPtr in
                Darwin.copyfile(srcPtr, dstPtr, nil, copyfile_flags_t(COPYFILE_CLONE | COPYFILE_ALL))
            }
        }
        if cloneResult == 0 { return }  // 클론 성공

        // 2차: F_NOCACHE + 8MB 버퍼 직접 복사 (캐시 bypass → 메모리 효율 + 속도)
        let srcFD = open(src, O_RDONLY)
        guard srcFD >= 0 else {
            throw NSError(domain: "FileCopy", code: -1, userInfo: [NSLocalizedDescriptionKey: "소스 파일 열기 실패"])
        }
        defer { close(srcFD) }

        // 소스 파일 속성 가져오기
        var srcStat = stat()
        fstat(srcFD, &srcStat)

        let dstFD = open(dst, O_WRONLY | O_CREAT | O_TRUNC, srcStat.st_mode)
        guard dstFD >= 0 else {
            throw NSError(domain: "FileCopy", code: -2, userInfo: [NSLocalizedDescriptionKey: "대상 파일 생성 실패"])
        }
        defer { close(dstFD) }

        // F_NOCACHE: 커널 캐시 bypass (대용량 파일 복사 시 메모리 절약 + 속도 향상)
        fcntl(srcFD, F_NOCACHE, 1)
        fcntl(dstFD, F_NOCACHE, 1)

        // 8MB 버퍼로 복사
        let bufferSize = 8 * 1024 * 1024  // 8MB
        let buffer = UnsafeMutablePointer<UInt8>.allocate(capacity: bufferSize)
        defer { buffer.deallocate() }

        while true {
            let bytesRead = read(srcFD, buffer, bufferSize)
            if bytesRead <= 0 { break }
            var written = 0
            while written < bytesRead {
                let w = write(dstFD, buffer + written, bytesRead - written)
                if w < 0 {
                    throw NSError(domain: "FileCopy", code: -3, userInfo: [NSLocalizedDescriptionKey: "쓰기 실패"])
                }
                written += w
            }
        }
    }

    // MARK: - Standard Export (JPG + RAW folders)

    static func copyPhotos(
        photos: [PhotoItem],
        to destinationURL: URL,
        jpgFolderName: String = "JPG",
        rawFolderName: String = "RAW",
        duplicateHandling: DuplicateHandling = .overwrite,
        exportJPG: Bool = true,
        exportRAW: Bool = true,
        singleFolder: Bool = false,
        applyDevelopSettings: Bool = true,   // v8.6 — 보정값 적용 여부
        developJPEGQuality: CGFloat = 0.92,
        progress: @escaping (Int, Int) -> Void
    ) -> CopyResult {
        let fileManager = FileManager.default
        var result = CopyResult()

        let jpgName = jpgFolderName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "JPG" : jpgFolderName.trimmingCharacters(in: .whitespacesAndNewlines)
        let rawName = rawFolderName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "RAW" : rawFolderName.trimmingCharacters(in: .whitespacesAndNewlines)
        let jpgFolder = singleFolder ? destinationURL : destinationURL.appendingPathComponent(jpgName)
        let rawFolder = singleFolder ? destinationURL : destinationURL.appendingPathComponent(rawName)

        do {
            if !singleFolder {
                try fileManager.createDirectory(at: jpgFolder, withIntermediateDirectories: true)
                try fileManager.createDirectory(at: rawFolder, withIntermediateDirectories: true)
            }
        } catch {
            result.failedFiles.append("폴더 생성 실패: \(error.localizedDescription)")
            return result
        }

        // Build list of all copy operations (source → dest, type)
        enum CopyType { case jpg, raw, xmp }
        struct CopyOp {
            let source: URL
            let dest: URL
            let type: CopyType
            let fileName: String
            let skip: Bool
            /// v8.6 — 보정값 있으면 렌더링 경로로 분기. nil 이면 일반 복사.
            let developSettings: DevelopSettings?
        }

        var ops: [CopyOp] = []

        // 파이프라인 하나를 공유 (Metal context 재활용)
        let pipeline = DevelopPipeline()

        // JPG copies (skip RAW-only, skip if exportJPG=false)
        for photo in photos {
            if !exportJPG { break }
            if photo.isRawOnly { continue }

            // v8.6 — 보정 적용 여부 결정
            let settings = applyDevelopSettings ? DevelopStore.shared.get(for: photo.jpgURL) : DevelopSettings()
            let hasDevelopChanges = !settings.isDefault
            let opSettings: DevelopSettings? = hasDevelopChanges ? settings : nil

            // 보정 적용 시 항상 .jpg 확장자로 저장 (RAW-only photo 라도)
            var destURL: URL
            if hasDevelopChanges {
                // 원본 JPG/RAW → "<basename>.jpg" 로 저장
                let base = photo.jpgURL.deletingPathExtension().lastPathComponent
                destURL = jpgFolder.appendingPathComponent(base + ".jpg")
            } else {
                destURL = jpgFolder.appendingPathComponent(photo.jpgURL.lastPathComponent)
            }

            var shouldSkip = false
            if fileManager.fileExists(atPath: destURL.path) {
                switch duplicateHandling {
                case .skip:
                    shouldSkip = true
                case .rename:
                    destURL = uniqueURL(for: destURL)
                case .overwrite:
                    try? fileManager.removeItem(at: destURL)
                }
            }
            ops.append(CopyOp(
                source: photo.jpgURL,
                dest: destURL,
                type: .jpg,
                fileName: photo.fileName,
                skip: shouldSkip,
                developSettings: opSettings
            ))
        }

        // RAW copies (skip if exportRAW=false)
        for photo in photos where photo.hasRAW && exportRAW {
            guard let rawURL = photo.rawURL else { continue }
            var destURL = rawFolder.appendingPathComponent(rawURL.lastPathComponent)
            var shouldSkip = false
            if fileManager.fileExists(atPath: destURL.path) {
                switch duplicateHandling {
                case .skip:
                    shouldSkip = true
                case .rename:
                    destURL = uniqueURL(for: destURL)
                case .overwrite:
                    try? fileManager.removeItem(at: destURL)
                }
            }
            ops.append(CopyOp(source: rawURL, dest: destURL, type: .raw, fileName: photo.fileName, skip: shouldSkip, developSettings: nil))
        }

        // XMP sidecar copies — 영상 파일에 IN/OUT 마커 XMP 있으면 함께 이동
        // (photo.jpgURL.xmp 형식: MVI_0042.MOV.xmp)
        for photo in photos where photo.isVideoFile {
            let xmpSource = photo.jpgURL.appendingPathExtension("xmp")
            guard fileManager.fileExists(atPath: xmpSource.path) else { continue }
            // 영상 원본이 복사될 폴더에 동일 basename 으로 xmp 도 복사
            let targetFolder = jpgFolder  // 영상은 JPG 폴더 쪽으로 감 (photo.jpgURL 이 영상 원본)
            var xmpDest = targetFolder.appendingPathComponent(xmpSource.lastPathComponent)
            var shouldSkip = false
            if fileManager.fileExists(atPath: xmpDest.path) {
                switch duplicateHandling {
                case .skip:
                    shouldSkip = true
                case .rename:
                    xmpDest = uniqueURL(for: xmpDest)
                case .overwrite:
                    try? fileManager.removeItem(at: xmpDest)
                }
            }
            ops.append(CopyOp(source: xmpSource, dest: xmpDest, type: .xmp, fileName: xmpSource.lastPathComponent, skip: shouldSkip, developSettings: nil))
        }

        let totalOperations = ops.count
        result.totalFiles = totalOperations

        // Parallel copy — 동시성 4개로 캡 (세마포어)
        // 과거: concurrentPerform → 무제한 동시성 + fastCopy 8MB 버퍼 × 스레드 수 (대량 복사 시 메모리 폭증)
        // 현재: 코어 수 기반 2~4 동시성 제한 (I/O 바운드 작업에서 과도한 스레드 경쟁 방지)
        let lock = NSLock()
        var completed = 0
        let copyStart = CFAbsoluteTimeGetCurrent()

        // SystemSpec tier 기반 동시성 (standard = 3, high = 4, extreme = 6)
        let limit = SystemSpec.shared.fileCopyConcurrency()
        let semaphore = DispatchSemaphore(value: limit)
        let group = DispatchGroup()
        let workQueue = DispatchQueue.global(qos: .userInitiated)

        for index in 0..<ops.count {
            semaphore.wait()
            group.enter()
            workQueue.async {
                defer {
                    semaphore.signal()
                    group.leave()
                }

                let op = ops[index]

                if op.skip {
                    lock.lock()
                    result.skipped += 1
                    completed += 1
                    let c = completed
                    lock.unlock()
                    DispatchQueue.main.async { progress(c, totalOperations) }
                    return
                }

                // v8.6 — 보정값 있으면 렌더링 경로로, 없으면 빠른 파일 복사
                var succeeded = false
                if let settings = op.developSettings, op.type == .jpg {
                    succeeded = pipeline.renderToJPEG(
                        url: op.source,
                        settings: settings,
                        dest: op.dest,
                        quality: developJPEGQuality
                    )
                } else {
                    do {
                        try fastCopy(from: op.source, to: op.dest)
                        succeeded = true
                    } catch {
                        succeeded = false
                    }
                }

                if succeeded {
                    lock.lock()
                    switch op.type {
                    case .jpg: result.copiedJPG += 1
                    case .raw: result.copiedRAW += 1
                    case .xmp: result.copiedJPG += 1
                    }
                    completed += 1
                    let c = completed
                    lock.unlock()
                    DispatchQueue.main.async { progress(c, totalOperations) }
                } else {
                    let msg: String
                    switch op.type {
                    case .jpg: msg = op.developSettings != nil ? "JPG 보정 저장 실패: \(op.fileName)" : "JPG 복사 실패: \(op.fileName)"
                    case .raw: msg = "RAW 복사 실패: \(op.fileName)"
                    case .xmp: msg = "XMP 복사 실패: \(op.fileName)"
                    }
                    lock.lock()
                    result.failedFiles.append(msg)
                    completed += 1
                    let c = completed
                    lock.unlock()
                    DispatchQueue.main.async { progress(c, totalOperations) }
                }
            }
        }

        group.wait()

        let copyElapsed = CFAbsoluteTimeGetCurrent() - copyStart
        let totalCopied = result.copiedJPG + result.copiedRAW
        fputs("[COPY] \(totalCopied)파일 복사 완료 \(String(format: "%.1f", copyElapsed))초\n", stderr)

        result.verified = verify(photos: photos, jpgFolder: jpgFolder, rawFolder: rawFolder)
        return result
    }

    // MARK: - Lightroom Export (RAW + XMP sidecar with ratings)

    static func exportForLightroom(
        photos: [PhotoItem],
        to destinationURL: URL,
        duplicateHandling: DuplicateHandling = .overwrite,
        progress: @escaping (Int, Int) -> Void
    ) -> CopyResult {
        let fileManager = FileManager.default
        var result = CopyResult()

        // Lightroom expects RAW + XMP in the same folder
        do {
            try fileManager.createDirectory(at: destinationURL, withIntermediateDirectories: true)
        } catch {
            result.failedFiles.append("폴더 생성 실패: \(error.localizedDescription)")
            return result
        }

        // RAW + JPG 모두 지원 (JPG only도 XMP 생성)
        // 각 사진: 파일복사(1) + XMP(1) + JPG쌍복사(RAW+JPG 페어일 때 1)
        let pairsCount = photos.filter { $0.hasRAW && !$0.isRawOnly }.count
        let totalOperations = photos.count * 2 + pairsCount
        result.totalFiles = totalOperations
        var completed = 0

        for photo in photos {
            // 1. 파일 복사 (RAW 우선, 없으면 JPG)
            let sourceURL = photo.rawURL ?? photo.jpgURL
            var destFile = destinationURL.appendingPathComponent(sourceURL.lastPathComponent)

            if fileManager.fileExists(atPath: destFile.path) {
                switch duplicateHandling {
                case .skip:
                    result.skipped += 1
                    completed += 2  // 파일 + XMP 건너뛰기
                    progress(completed, totalOperations)
                    continue
                case .rename:
                    destFile = uniqueURL(for: destFile)
                case .overwrite:
                    try? fileManager.removeItem(at: destFile)
                }
            }

            do {
                try fastCopy(from: sourceURL, to: destFile)
                if photo.hasRAW { result.copiedRAW += 1 } else { result.copiedJPG += 1 }
            } catch {
                result.failedFiles.append("복사 실패: \(photo.fileName)")
            }

            // JPG도 같이 복사 (RAW+JPG 쌍일 때만 — RAW only는 제외)
            if photo.hasRAW && !photo.isRawOnly {
                var jpgDest = destinationURL.appendingPathComponent(photo.jpgURL.lastPathComponent)
                if fileManager.fileExists(atPath: jpgDest.path) {
                    switch duplicateHandling {
                    case .skip:
                        result.skipped += 1
                    case .rename:
                        jpgDest = uniqueURL(for: jpgDest)
                        try? fastCopy(from: photo.jpgURL, to: jpgDest)
                        result.copiedJPG += 1
                    case .overwrite:
                        try? fileManager.removeItem(at: jpgDest)
                        try? fastCopy(from: photo.jpgURL, to: jpgDest)
                        result.copiedJPG += 1
                    }
                } else {
                    try? fastCopy(from: photo.jpgURL, to: jpgDest)
                    result.copiedJPG += 1
                }
                completed += 1
                progress(completed, totalOperations)
            }

            completed += 1
            progress(completed, totalOperations)

            // 2. XMP sidecar 생성 (RAW 또는 JPG 파일명 기준)
            let xmpFileName = sourceURL.deletingPathExtension().lastPathComponent + ".xmp"
            let xmpDest = destinationURL.appendingPathComponent(xmpFileName)
            do {
                let xmpContent = generateXMP(rating: photo.rating, isSpacePicked: photo.isSpacePicked, fileName: sourceURL.lastPathComponent)
                try xmpContent.write(to: xmpDest, atomically: true, encoding: .utf8)
                result.copiedXMP += 1
            } catch {
                result.failedFiles.append("XMP 생성 실패: \(photo.fileName)")
            }
            completed += 1
            progress(completed, totalOperations)
        }

        result.verified = result.failedFiles.isEmpty
        return result
    }

    // MARK: - XMP Sidecar Generation

    private static func generateXMP(rating: Int, isSpacePicked: Bool = false, fileName: String) -> String {
        let ratingValue = max(0, min(5, rating))
        // Space Pick → Red label for Lightroom filtering; otherwise use rating-based label
        let label: String
        if isSpacePicked {
            label = "Red"
        } else {
            switch ratingValue {
            case 5: label = "Winner"
            case 4: label = "Winner"
            case 3: label = "Approved"
            case 2: label = "Review"
            case 1: label = "To Do"
            default: label = ""
            }
        }

        return """
        <?xml version="1.0" encoding="UTF-8"?>
        <x:xmpmeta xmlns:x="adobe:ns:meta/" x:xmptk="PickShot v6.0">
          <rdf:RDF xmlns:rdf="http://www.w3.org/1999/02/22-rdf-syntax-ns#">
            <rdf:Description rdf:about=""
              xmlns:xmp="http://ns.adobe.com/xap/1.0/"
              xmlns:xmpMM="http://ns.adobe.com/xap/1.0/mm/"
              xmlns:dc="http://purl.org/dc/elements/1.1/"
              xmlns:crs="http://ns.adobe.com/camera-raw-settings/1.0/"
              xmp:Rating="\(ratingValue)"
              xmp:Label="\(label)"
              xmp:CreatorTool="PickShot v6.0"
              crs:RawFileName="\(fileName.replacingOccurrences(of: "&", with: "&amp;").replacingOccurrences(of: "\"", with: "&quot;").replacingOccurrences(of: "<", with: "&lt;").replacingOccurrences(of: ">", with: "&gt;"))">
            </rdf:Description>
          </rdf:RDF>
        </x:xmpmeta>
        """
    }

    // MARK: - Open Lightroom

    static func openLightroom(folderURL: URL) {
        let lightroomPaths = [
            "/Applications/Adobe Lightroom Classic/Adobe Lightroom Classic.app",
            "/Applications/Adobe Lightroom Classic.app",
            "/Applications/Adobe Lightroom.app"
        ]

        for path in lightroomPaths {
            let url = URL(fileURLWithPath: path)
            if FileManager.default.fileExists(atPath: path) {
                NSWorkspace.shared.open(
                    [folderURL],
                    withApplicationAt: url,
                    configuration: NSWorkspace.OpenConfiguration()
                )
                return
            }
        }

        // Lightroom not found - just open folder in Finder
        NSWorkspace.shared.open(folderURL)
    }

    // MARK: - Verify

    private static func verify(
        photos: [PhotoItem],
        jpgFolder: URL,
        rawFolder: URL
    ) -> Bool {
        let fileManager = FileManager.default

        for photo in photos {
            // RAW-only 파일은 JPG 폴더가 아닌 RAW 폴더에서 확인
            if !photo.isRawOnly {
                let jpgDest = jpgFolder.appendingPathComponent(photo.jpgURL.lastPathComponent)
                guard fileManager.fileExists(atPath: jpgDest.path) else { return false }

                guard let srcSize = try? fileManager.attributesOfItem(atPath: photo.jpgURL.path)[.size] as? Int,
                      let dstSize = try? fileManager.attributesOfItem(atPath: jpgDest.path)[.size] as? Int,
                      srcSize == dstSize else {
                    return false
                }
            }

            if let rawURL = photo.rawURL {
                let rawDest = rawFolder.appendingPathComponent(rawURL.lastPathComponent)
                guard fileManager.fileExists(atPath: rawDest.path) else { return false }

                guard let srcRawSize = try? fileManager.attributesOfItem(atPath: rawURL.path)[.size] as? Int,
                      let dstRawSize = try? fileManager.attributesOfItem(atPath: rawDest.path)[.size] as? Int,
                      srcRawSize == dstRawSize else {
                    return false
                }
            }
        }
        return true
    }
}
