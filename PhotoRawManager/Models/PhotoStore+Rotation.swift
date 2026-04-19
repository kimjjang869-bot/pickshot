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

    /// 직렬 큐 — 빠른 연속 클릭 시에도 회전 작업이 인터리브 되지 않도록.
    private static let rotationQueue = DispatchQueue(label: "com.pickshot.batchRotate", qos: .userInitiated)

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

        // v8.6.2: 확인 다이얼로그 제거 — 즉시 실행 (되돌리기는 회전 반대방향 재적용)

        // 백그라운드에서 실제 회전 수행 — 직렬 큐로 연속 클릭도 순서 보장
        let photosSnapshot = targetPhotos
        PhotoStore.rotationQueue.async { [weak self] in
            guard let self = self else { return }
            var success = 0
            var failed = 0
            var overrideMap = PhotoStore.loadRotationOverrides()

            for photo in photosSnapshot {
                // URL 별로 타입 분리 — JPG 는 파일 EXIF 수정 (ImageIO 자동 반영), RAW 는 XMP + override
                var allOK = true
                let jpgExt = photo.jpgURL.pathExtension.lowercased()
                let jpgIsJPG = (jpgExt == "jpg" || jpgExt == "jpeg")

                // 1. jpgURL 회전
                if RotationService.rotate(url: photo.jpgURL, degreesCW: degreesCW) {
                    if jpgIsJPG {
                        // JPG — 파일 EXIF 가 수정됨 → ImageIO 가 자동 읽음 → override 는 0
                        overrideMap.removeValue(forKey: photo.jpgURL.path)
                    } else {
                        // jpgURL 이 실제로 RAW (JPG 없는 RAW 단독) — XMP 기록됨, override 누적
                        let prev = overrideMap[photo.jpgURL.path] ?? 0
                        let next = ((prev + degreesCW) % 360 + 360) % 360
                        if next == 0 { overrideMap.removeValue(forKey: photo.jpgURL.path) }
                        else { overrideMap[photo.jpgURL.path] = next }
                    }
                } else {
                    allOK = false
                }

                // 2. rawURL 회전 (RAW+JPG 쌍일 때만)
                if let raw = photo.rawURL, raw != photo.jpgURL {
                    if RotationService.rotate(url: raw, degreesCW: degreesCW) {
                        // RAW — XMP 사이드카 기록됨. ImageIO 는 XMP 를 읽지 않으므로 override 누적 필요.
                        let prev = overrideMap[raw.path] ?? 0
                        let next = ((prev + degreesCW) % 360 + 360) % 360
                        if next == 0 { overrideMap.removeValue(forKey: raw.path) }
                        else { overrideMap[raw.path] = next }
                    } else {
                        allOK = false
                    }
                }

                if allOK {
                    success += 1
                    // 캐시 무효화
                    ThumbnailCache.shared.remove(url: photo.jpgURL)
                    if let raw = photo.rawURL { ThumbnailCache.shared.remove(url: raw) }
                    DiskThumbnailCache.shared.invalidate(url: photo.jpgURL)
                    if let raw = photo.rawURL { DiskThumbnailCache.shared.invalidate(url: raw) }
                    // 미리보기 캐시: 해상도 suffix 키 + orig 키 모두 제거
                    let baseURLs: [URL] = {
                        var arr: [URL] = [photo.jpgURL]
                        if let r = photo.rawURL, r != photo.jpgURL { arr.append(r) }
                        return arr
                    }()
                    let suffixes = ["r600", "r800", "r1000", "r1200", "r1600", "r2000", "r2400", "r3000", "orig"]
                    for base in baseURLs {
                        PreviewImageCache.shared.remove(url: base)
                        for suf in suffixes {
                            PreviewImageCache.shared.remove(url: base.appendingPathExtension(suf))
                        }
                    }
                } else {
                    failed += 1
                }
            }

            PhotoStore.saveRotationOverrides(overrideMap)

            DispatchQueue.main.async {
                self.photosVersion += 1
                // v8.6.2: 모든 AsyncThumbnailView/미리보기에 회전 통지 → @State image 강제 재로드
                for photo in photosSnapshot {
                    NotificationCenter.default.post(name: AsyncThumbnailView.rotationInvalidateNotification, object: photo.jpgURL)
                    if let raw = photo.rawURL, raw != photo.jpgURL {
                        NotificationCenter.default.post(name: AsyncThumbnailView.rotationInvalidateNotification, object: raw)
                    }
                    // displayURL 도 (RAW+JPG 쌍에서 AsyncThumbnailView 는 displayURL 로 로드)
                    let disp = photo.displayURL
                    if disp != photo.jpgURL && disp != (photo.rawURL ?? photo.jpgURL) {
                        NotificationCenter.default.post(name: AsyncThumbnailView.rotationInvalidateNotification, object: disp)
                    }
                }
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
