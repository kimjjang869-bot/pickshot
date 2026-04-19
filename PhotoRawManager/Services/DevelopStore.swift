import Foundation
import SwiftUI

/// DevelopSettings 의 이중 저장소 (UserDefaults L1 + 폴더 사이드카 L2).
///
/// 사용 예:
/// ```
/// DevelopStore.shared.get(for: url)
/// DevelopStore.shared.set(settings, for: url)
/// ```
///
/// 저장 타이밍: 슬라이더 드래그 중 디바운스 0.15초, 드래그 끝나면 즉시 flush.
/// 원본 파일은 절대 수정되지 않음.
final class DevelopStore: ObservableObject {

    static let shared = DevelopStore()

    // MARK: - Constants

    private let udPrefix = "develop:"
    private let sidecarFilename = ".pickshot_develop.json"

    // MARK: - Memory Cache

    /// URL path → settings. 메모리 캐시 (hit 99% 기대).
    private var memory: [String: DevelopSettings] = [:]

    /// 사이드카 파일 dirty 여부 (폴더 경로 → dirty).
    private var sidecarDirty: Set<String> = []

    /// 디바운스 타이머
    private var flushTask: DispatchWorkItem?

    private let queue = DispatchQueue(label: "com.pickshot.develop-store", qos: .userInitiated)

    // MARK: - Sidecar Container

    private struct SidecarContainer: Codable {
        var version: Int = 1
        var photos: [String: DevelopSettings] = [:]  // 파일명(확장자 포함) → 설정
    }

    // MARK: - Public API

    /// 특정 사진의 보정값 가져오기. 없으면 기본값.
    func get(for url: URL) -> DevelopSettings {
        let key = url.path
        if let cached = memory[key] { return cached }

        // L1 — UserDefaults 시도
        if let data = UserDefaults.standard.data(forKey: udPrefix + key),
           let decoded = try? JSONDecoder().decode(DevelopSettings.self, from: data) {
            memory[key] = decoded
            return decoded
        }

        // L2 — 사이드카 시도
        if let settings = loadFromSidecar(for: url) {
            memory[key] = settings
            // L1 에도 캐시
            if let data = try? JSONEncoder().encode(settings) {
                UserDefaults.standard.set(data, forKey: udPrefix + key)
            }
            return settings
        }

        // 없음 → 기본값 (캐시엔 안 넣음, 기본값은 저장 안 함)
        return DevelopSettings()
    }

    /// v8.6.1: 삭제된 사진의 메모리/UserDefaults 엔트리 제거 (누수 방지).
    func invalidateMemory(for url: URL) {
        let key = url.path
        memory.removeValue(forKey: key)
        UserDefaults.standard.removeObject(forKey: udPrefix + key)
    }

    /// 보정값 저장. 기본값이면 실제로는 삭제.
    func set(_ settings: DevelopSettings, for url: URL) {
        let key = url.path
        if settings.isDefault {
            memory.removeValue(forKey: key)
            UserDefaults.standard.removeObject(forKey: udPrefix + key)
        } else {
            memory[key] = settings
            // L1 즉시 저장 (빠름)
            if let data = try? JSONEncoder().encode(settings) {
                UserDefaults.standard.set(data, forKey: udPrefix + key)
            }
        }
        // L2 는 디바운스 — 폴더 단위로 묶어서 한 번에 flush
        markSidecarDirty(for: url)
        scheduleFlush()

        // ObservableObject 통지
        DispatchQueue.main.async { self.objectWillChange.send() }
    }

    /// 현재 사진의 보정값을 복사 (클립보드).
    private(set) var clipboard: DevelopSettings? = nil

    func copyToClipboard(_ settings: DevelopSettings) {
        clipboard = settings
    }

    /// 클립보드 내용을 여러 URL 에 적용. components 로 부분 적용 가능.
    func pasteFromClipboard(
        to urls: [URL],
        components: Set<DevelopSettings.ComponentMask> = Set(DevelopSettings.ComponentMask.allCases)
    ) -> Int {
        guard let src = clipboard else { return 0 }
        var applied = 0
        for url in urls {
            var current = get(for: url)
            current.apply(src, components: components)
            set(current, for: url)
            applied += 1
        }
        return applied
    }

    // MARK: - Sidecar I/O

    private func loadFromSidecar(for url: URL) -> DevelopSettings? {
        let folder = url.deletingLastPathComponent()
        let sidecar = folder.appendingPathComponent(sidecarFilename)
        guard FileManager.default.fileExists(atPath: sidecar.path),
              let data = try? Data(contentsOf: sidecar),
              let container = try? JSONDecoder().decode(SidecarContainer.self, from: data) else {
            return nil
        }
        return container.photos[url.lastPathComponent]
    }

    private func markSidecarDirty(for url: URL) {
        sidecarDirty.insert(url.deletingLastPathComponent().path)
    }

    private func scheduleFlush() {
        flushTask?.cancel()
        let task = DispatchWorkItem { [weak self] in self?.flushSidecars() }
        flushTask = task
        queue.asyncAfter(deadline: .now() + 0.15, execute: task)
    }

    /// Dirty 로 마크된 폴더들의 사이드카를 실제 디스크에 기록.
    private func flushSidecars() {
        let folders = sidecarDirty
        sidecarDirty.removeAll()

        for folderPath in folders {
            let folderURL = URL(fileURLWithPath: folderPath)
            let sidecarURL = folderURL.appendingPathComponent(sidecarFilename)

            // 해당 폴더의 모든 사진 중 memory 에 있는 걸로 container 구성
            var container = SidecarContainer()
            // 기존 사이드카 읽어서 유지 (다른 사진 설정 날리지 않도록)
            if let data = try? Data(contentsOf: sidecarURL),
               let existing = try? JSONDecoder().decode(SidecarContainer.self, from: data) {
                container = existing
            }
            // 메모리 캐시 덮어쓰기
            for (path, settings) in memory {
                let url = URL(fileURLWithPath: path)
                guard url.deletingLastPathComponent().path == folderPath else { continue }
                if settings.isDefault {
                    container.photos.removeValue(forKey: url.lastPathComponent)
                } else {
                    container.photos[url.lastPathComponent] = settings
                }
            }

            // 비어 있으면 파일 삭제
            if container.photos.isEmpty {
                try? FileManager.default.removeItem(at: sidecarURL)
                continue
            }

            if let encoded = try? JSONEncoder().encode(container) {
                try? encoded.write(to: sidecarURL, options: .atomic)
            }
        }
    }

    /// 앱 종료 직전 강제 flush (AppDelegate 에서 호출).
    func flushImmediately() {
        flushTask?.cancel()
        flushSidecars()
    }

    // MARK: - Preset Library

    private var presetsDirectory: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        let dir = base.appendingPathComponent("PickShot").appendingPathComponent("Presets")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    /// 저장된 모든 프리셋 (사용자 + Built-in) 반환.
    func loadAllPresets() -> [DevelopSettings.Preset] {
        let urls = (try? FileManager.default.contentsOfDirectory(
            at: presetsDirectory,
            includingPropertiesForKeys: nil
        )) ?? []
        var presets: [DevelopSettings.Preset] = []
        for url in urls where url.pathExtension == "pickshot-preset" {
            if let data = try? Data(contentsOf: url),
               let preset = try? JSONDecoder().decode(DevelopSettings.Preset.self, from: data) {
                presets.append(preset)
            }
        }
        presets.sort { $0.createdAt > $1.createdAt }
        return presets + DevelopStore.builtinPresets()
    }

    func savePreset(_ preset: DevelopSettings.Preset) {
        let url = presetsDirectory.appendingPathComponent("\(preset.id).pickshot-preset")
        if let data = try? JSONEncoder().encode(preset) {
            try? data.write(to: url, options: .atomic)
        }
    }

    func deletePreset(_ preset: DevelopSettings.Preset) {
        let url = presetsDirectory.appendingPathComponent("\(preset.id).pickshot-preset")
        try? FileManager.default.removeItem(at: url)
    }

    /// 번들된 기본 프리셋 3종. UI 에 같이 노출하고 삭제 불가.
    static func builtinPresets() -> [DevelopSettings.Preset] {
        var natural = DevelopSettings()
        natural.wbAuto = true
        natural.exposure = 0.1

        var bright = DevelopSettings()
        bright.wbAuto = true
        bright.exposure = 0.5
        bright.curvePoints = [
            CGPoint(x: 0, y: 0),
            CGPoint(x: 0.25, y: 0.3),
            CGPoint(x: 0.5, y: 0.55),
            CGPoint(x: 0.75, y: 0.8),
            CGPoint(x: 1, y: 1)
        ]

        var film = DevelopSettings()
        film.temperature = 8
        film.tint = -3
        film.exposure = -0.2
        film.curvePoints = [
            CGPoint(x: 0, y: 0.05),
            CGPoint(x: 0.3, y: 0.28),
            CGPoint(x: 0.65, y: 0.68),
            CGPoint(x: 1, y: 0.93)
        ]

        return [
            .init(name: "자연스러운 피부톤", summary: natural.shortSummary, settings: natural),
            .init(name: "웨딩 하이키", summary: bright.shortSummary, settings: bright),
            .init(name: "필름 톤", summary: film.shortSummary, settings: film)
        ]
    }
}
