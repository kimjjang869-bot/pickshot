//
//  CacheSettingsTab.swift
//  PhotoRawManager
//
//  Extracted from SettingsView.swift split.
//

import SwiftUI


struct CacheSettingsTab: View {
    @AppStorage("thumbnailCacheMaxGB") private var thumbnailCacheMaxGB: Double = 2.0
    @AppStorage("customCachePath") private var customCachePath: String = ""
    @State private var thumbCacheSize: String = "계산 중..."
    @State private var previewCacheSize: String = "계산 중..."
    @State private var logCacheSize: String = "계산 중..."
    @State private var totalCacheSize: String = "계산 중..."
    @State private var isClearing = false

    private var effectiveCachePath: String {
        customCachePath.isEmpty ? defaultCachePath : customCachePath
    }

    private var defaultCachePath: String {
        let cachesDir = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        return cachesDir.appendingPathComponent("PickShot").path
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                GroupBox("캐시 현황") {
                    VStack(spacing: 8) {
                        cacheRow(icon: "photo.stack", label: "썸네일 캐시", size: thumbCacheSize, color: .blue)
                        cacheRow(icon: "eye", label: "미리보기 캐시", size: previewCacheSize, color: .green)
                        cacheRow(icon: "doc.text", label: "로그", size: logCacheSize, color: .gray)
                        Divider()
                        HStack {
                            Image(systemName: "internaldrive").font(.system(size: 14)).foregroundColor(.accentColor)
                            Text("총 캐시 용량").font(.system(size: 13, weight: .bold))
                            Spacer()
                            Text(totalCacheSize).font(.system(size: 13, weight: .bold, design: .monospaced)).foregroundColor(.accentColor)
                        }
                    }.padding(4)
                }

                GroupBox("캐시 크기 제한") {
                    VStack(alignment: .leading, spacing: 10) {
                        HStack {
                            Text("썸네일 캐시 최대").frame(width: 130, alignment: .leading)
                            Slider(value: $thumbnailCacheMaxGB, in: 0.5...10, step: 0.5)
                            Text("\(thumbnailCacheMaxGB, specifier: "%.1f") GB").font(.system(size: 12, design: .monospaced)).frame(width: 55, alignment: .trailing)
                        }
                        Text("초과 시 오래된 항목부터 자동 삭제").font(.system(size: 11)).foregroundColor(.secondary)
                    }.padding(4)
                }

                GroupBox("캐시 저장 위치") {
                    VStack(alignment: .leading, spacing: 10) {
                        HStack {
                            Image(systemName: "folder").foregroundColor(.secondary)
                            Text(effectiveCachePath).font(.system(size: 11, design: .monospaced)).lineLimit(1).truncationMode(.middle).foregroundColor(.secondary)
                            Spacer()
                        }.padding(6).background(Color.gray.opacity(0.1)).cornerRadius(4)

                        HStack(spacing: 8) {
                            Button("위치 변경...") {
                                let panel = NSOpenPanel()
                                panel.canChooseDirectories = true
                                panel.canChooseFiles = false
                                panel.message = "캐시 파일을 저장할 폴더를 선택하세요"
                                if panel.runModal() == .OK, let url = panel.url {
                                    customCachePath = url.appendingPathComponent("PickShot").path
                                }
                            }
                            if !customCachePath.isEmpty {
                                Button("기본 위치로") { customCachePath = "" }
                            }
                            Button("Finder에서 열기") {
                                let path = effectiveCachePath
                                let url = URL(fileURLWithPath: path)
                                if FileManager.default.fileExists(atPath: path) {
                                    NSWorkspace.shared.open(url)
                                }
                            }
                        }
                        Text("변경 시 기존 캐시는 이동되지 않습니다").font(.system(size: 11)).foregroundColor(.secondary)
                    }.padding(4)
                }

                GroupBox("캐시 삭제") {
                    VStack(spacing: 10) {
                        HStack(spacing: 10) {
                            Button(action: { clearCache(type: .thumb) }) { Label("썸네일", systemImage: "trash") }.disabled(isClearing)
                            Button(action: { clearCache(type: .preview) }) { Label("미리보기", systemImage: "trash") }.disabled(isClearing)
                            Button(action: { clearCache(type: .all) }) { Label("전체 삭제", systemImage: "trash.fill") }.foregroundColor(.red).disabled(isClearing)
                        }
                        if isClearing { ProgressView("삭제 중...").controlSize(.small) }
                        Text("삭제 후 다음 로딩 시 캐시가 다시 생성됩니다").font(.system(size: 11)).foregroundColor(.secondary)
                    }.padding(4)
                }

            }.padding(20)
        }
        .onAppear { refreshCacheSizes() }
        .onReceive(NotificationCenter.default.publisher(for: .init("SettingsResetTab"))) { _ in
            thumbnailCacheMaxGB = 2.0; customCachePath = ""
        }
    }

    private func cacheRow(icon: String, label: String, size: String, color: Color) -> some View {
        HStack {
            Image(systemName: icon).font(.system(size: 12)).foregroundColor(color).frame(width: 20)
            Text(label).font(.system(size: 12))
            Spacer()
            Text(size).font(.system(size: 12, design: .monospaced)).foregroundColor(.secondary)
        }
    }

    private enum ClearType { case thumb, preview, all }

    private func clearCache(type: ClearType) {
        isClearing = true
        DispatchQueue.global(qos: .utility).async {
            switch type {
            case .thumb:
                DiskThumbnailCache.shared.clearAll()
                ThumbnailCache.shared.removeAll()
            case .preview:
                PreviewImageCache.shared.clearCache()
                try? FileManager.default.removeItem(atPath: "/tmp/pickshot_cache")
            case .all:
                DiskThumbnailCache.shared.clearAll()
                ThumbnailCache.shared.removeAll()
                PreviewImageCache.shared.clearCache()
                try? FileManager.default.removeItem(atPath: "/tmp/pickshot_cache")
                ExifService.clearCache()
            }
            DispatchQueue.main.async { isClearing = false; refreshCacheSizes() }
        }
    }

    private func refreshCacheSizes() {
        DispatchQueue.global(qos: .utility).async {
            let thumb = folderSize(path: defaultCachePath + "/thumbnails")
            let preview = folderSize(path: "/tmp/pickshot_cache")
            let log = folderSize(path: defaultCachePath + "/logs")
            let total = thumb + preview + log
            DispatchQueue.main.async {
                thumbCacheSize = formatBytes(thumb)
                previewCacheSize = formatBytes(preview)
                logCacheSize = formatBytes(log)
                totalCacheSize = formatBytes(total)
            }
        }
    }

    private func folderSize(path: String) -> Int64 {
        let fm = FileManager.default
        guard let enumerator = fm.enumerator(atPath: path) else { return 0 }
        var total: Int64 = 0
        while let file = enumerator.nextObject() as? String {
            let fullPath = (path as NSString).appendingPathComponent(file)
            if let attrs = try? fm.attributesOfItem(atPath: fullPath), let size = attrs[.size] as? Int64 { total += size }
        }
        return total
    }

    private func formatBytes(_ bytes: Int64) -> String {
        if bytes == 0 { return "0 MB" }
        let gb = Double(bytes) / 1_073_741_824
        return gb >= 1 ? String(format: "%.1f GB", gb) : String(format: "%.0f MB", Double(bytes) / 1_048_576)
    }
}

// MARK: - Performance Optimize Tab (성능 최적화)
