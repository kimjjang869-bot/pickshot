//
//  PhotoStore+Rotation.swift
//  PhotoRawManager
//
//  v8.6.2: 일괄 회전 기능 — JPG/RAW 동시 지원.
//  - JPG: lossless EXIF 재기록
//  - RAW: XMP 사이드카 (Lightroom/C1/Bridge 호환)
//  - 앱 내부 표시: rotationOverrideCW 맵으로 후처리 회전 (delta)
//

import Foundation
import AppKit

extension PhotoStore {

    /// 키: displayURL.path  (RAW+JPG 쌍이면 RAW 경로)
    /// 값: CW 각도 (0/90/180/270). 0은 맵에 저장 안 함.
    private static let rotationOverrideKey = "rotationOverrideCW_v1"

    /// 회전 override 맵 조회 (UserDefaults 영속)
    static func loadRotationOverrides() -> [String: Int] {
        return (UserDefaults.standard.dictionary(forKey: rotationOverrideKey) as? [String: Int]) ?? [:]
    }

    static func saveRotationOverrides(_ map: [String: Int]) {
        UserDefaults.standard.set(map, forKey: rotationOverrideKey)
    }

    static func rotationOverrideCW(for url: URL) -> Int {
        return loadRotationOverrides()[url.path] ?? 0
    }

    static func setRotationOverrideCW(_ deg: Int, for url: URL) {
        var map = loadRotationOverrides()
        let normalized = ((deg % 360) + 360) % 360
        if normalized == 0 {
            map.removeValue(forKey: url.path)
        } else {
            map[url.path] = normalized
        }
        saveRotationOverrides(map)
    }

    // MARK: - 일괄 회전

    /// 다중 선택한 사진을 일괄 회전.
    /// - Parameters:
    ///   - ids: 대상 photoID 집합
    ///   - degreesCW: 90, 180, 270 중 하나
    func batchRotate(ids: Set<UUID>, degreesCW: Int) {
        guard [90, 180, 270].contains(degreesCW) else { return }

        // 확인 다이얼로그
        let targetPhotos: [PhotoItem] = ids.compactMap { id in
            guard let idx = self._photoIndex[id], idx < self.photos.count else { return nil }
            let p = self.photos[idx]
            guard !p.isFolder && !p.isParentFolder else { return nil }
            return p
        }
        guard !targetPhotos.isEmpty else { return }

        let alert = NSAlert()
        alert.messageText = "\(targetPhotos.count)장 회전"
        alert.informativeText = "\(degreesCW)° (시계방향) 회전을 적용합니다.\n• JPG — 파일 EXIF 수정 (무손실)\n• RAW — XMP 사이드카 생성 (Lightroom/C1 호환)"
        alert.addButton(withTitle: "회전")
        alert.addButton(withTitle: "취소")
        guard alert.runModal() == .alertFirstButtonReturn else { return }

        // 백그라운드에서 실제 회전 수행
        let photosSnapshot = targetPhotos
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let self = self else { return }
            var success = 0
            var failed = 0
            var overrideMap = PhotoStore.loadRotationOverrides()

            for photo in photosSnapshot {
                let urls: [URL] = {
                    var arr: [URL] = [photo.jpgURL]
                    if let raw = photo.rawURL, raw != photo.jpgURL { arr.append(raw) }
                    return arr
                }()
                var allOK = true
                for url in urls {
                    if !RotationService.rotate(url: url, degreesCW: degreesCW) {
                        allOK = false
                    }
                }
                if allOK {
                    success += 1
                    // 앱 내부 표시용 override 갱신 (displayURL 기준)
                    let key = photo.displayURL.path
                    let prev = overrideMap[key] ?? 0
                    let next = ((prev + degreesCW) % 360 + 360) % 360
                    if next == 0 {
                        overrideMap.removeValue(forKey: key)
                    } else {
                        overrideMap[key] = next
                    }
                    // 캐시 무효화
                    ThumbnailCache.shared.remove(url: photo.jpgURL)
                    if let raw = photo.rawURL { ThumbnailCache.shared.remove(url: raw) }
                    DiskThumbnailCache.shared.invalidate(url: photo.jpgURL)
                    if let raw = photo.rawURL { DiskThumbnailCache.shared.invalidate(url: raw) }
                    PreviewImageCache.shared.remove(url: photo.jpgURL)
                    if let raw = photo.rawURL { PreviewImageCache.shared.remove(url: raw) }
                } else {
                    failed += 1
                }
            }

            PhotoStore.saveRotationOverrides(overrideMap)

            DispatchQueue.main.async {
                self.photosVersion += 1
                let msg: String
                if failed == 0 {
                    msg = "↻ \(success)장 회전 완료 (\(degreesCW)°)"
                } else {
                    msg = "↻ \(success)장 완료 / \(failed)장 실패"
                }
                self.showToastMessage(msg)
            }
        }
    }
}
