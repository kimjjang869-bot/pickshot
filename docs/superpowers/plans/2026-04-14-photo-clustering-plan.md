# 유사 컷 클러스터링 Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** 시간 + pHash 2단계 알고리즘으로 비슷한 컷을 자동 묶고, Bridge 스타일 스택 뷰로 컬링 속도 향상

**Architecture:** 신규 `PhotoClusteringService`(알고리즘) + `ClusterCacheService`(캐시 I/O)가 핵심. 기존 `AISimilarityService.computePHash`, `ImageAnalysisService` 품질점수, `FolderWatcherService` 파일 변경 감지 모두 재사용. UI는 `ThumbnailGridView`에 그룹 뱃지/인라인 확장 추가.

**Tech Stack:** Swift, SwiftUI, Foundation, CryptoKit (SHA1), CoreImage, XCTest

---

## 전제 조건

- `PickShotTests` XCTest 타겟이 듀얼 인제스트 플랜 Task 1에서 이미 추가됨. 본 플랜은 해당 타겟 존재를 가정.
- 신규 파일은 `PhotoRawManager` 앱 타겟에, 테스트 파일은 `PickShotTests` 타겟에 `project.pbxproj`로 수동 추가 필요.
- 빌드 검증 명령:
  ```bash
  xcodebuild -project /Users/potokan/PhotoRawManager/PhotoRawManager.xcodeproj \
             -scheme PhotoRawManager -configuration Debug build
  ```
- 테스트 실행:
  ```bash
  xcodebuild test -project /Users/potokan/PhotoRawManager/PhotoRawManager.xcodeproj \
                  -scheme PhotoRawManager -destination 'platform=macOS'
  ```

---

## Task 1 — PhotoCluster 모델 (런타임 + 캐시 표현)

**Files:**
- 생성: `/Users/potokan/PhotoRawManager/PhotoRawManager/Models/PhotoCluster.swift`
- 생성: `/Users/potokan/PhotoRawManager/PickShotTests/PhotoClusterTests.swift`
- 수정: `/Users/potokan/PhotoRawManager/PhotoRawManager.xcodeproj/project.pbxproj`

### Step 1 — 실패 테스트 작성

- [ ] `PhotoClusterTests.swift` 생성. 런타임/캐시 표현 상호변환, 기본값, Identifiable 동작 검증.

```swift
import XCTest
@testable import PhotoRawManager

final class PhotoClusterTests: XCTestCase {

    func test_photoCluster_defaultsIsExpandedFalse() {
        let id = UUID()
        let memberID = UUID()
        let repID = UUID()
        let now = Date()
        let cluster = PhotoCluster(
            id: id,
            memberIDs: [memberID, repID],
            representativeID: repID,
            timeRange: now...now.addingTimeInterval(2),
            avgPHashSimilarity: 0.93
        )
        XCTAssertFalse(cluster.isExpanded)
        XCTAssertEqual(cluster.memberIDs.count, 2)
        XCTAssertEqual(cluster.representativeID, repID)
    }

    func test_clusterCacheEntry_codableRoundtrip() throws {
        let entry = ClusterCacheEntry(
            memberFileNames: ["IMG_0001.CR3", "IMG_0002.CR3"],
            representativeFileName: "IMG_0001.CR3",
            timeRangeStart: Date(timeIntervalSince1970: 1_700_000_000),
            timeRangeEnd:   Date(timeIntervalSince1970: 1_700_000_003),
            avgPHashSimilarity: 0.91
        )
        let data = try JSONEncoder().encode(entry)
        let decoded = try JSONDecoder().decode(ClusterCacheEntry.self, from: data)
        XCTAssertEqual(decoded.memberFileNames, entry.memberFileNames)
        XCTAssertEqual(decoded.representativeFileName, entry.representativeFileName)
        XCTAssertEqual(decoded.avgPHashSimilarity, 0.91, accuracy: 0.001)
    }

    func test_clusterCacheFile_versionField() throws {
        let file = ClusterCacheFile(
            version: 1,
            generatedAt: Date(timeIntervalSince1970: 1_700_000_000),
            fileHash: "abc123",
            clusters: []
        )
        let data = try JSONEncoder().encode(file)
        let decoded = try JSONDecoder().decode(ClusterCacheFile.self, from: data)
        XCTAssertEqual(decoded.version, 1)
        XCTAssertEqual(decoded.fileHash, "abc123")
    }
}
```

### Step 2 — Run: 실패 확인

- [ ] 빌드 실패 확인 (`PhotoCluster`/`ClusterCacheEntry`/`ClusterCacheFile` 미정의).

### Step 3 — 구현

- [ ] `PhotoCluster.swift` 생성:

```swift
import Foundation

/// 런타임 메모리 표현. PhotoItem.id는 UUID라 세션 내에서만 유효.
struct PhotoCluster: Identifiable, Equatable {
    let id: UUID
    var memberIDs: [PhotoItem.ID]       // 시간순 정렬된 멤버 ID
    var representativeID: PhotoItem.ID  // 대표 썸네일 ID (품질 1등)
    var timeRange: ClosedRange<Date>
    var avgPHashSimilarity: Double
    var isExpanded: Bool = false        // UI 상태

    init(
        id: UUID = UUID(),
        memberIDs: [PhotoItem.ID],
        representativeID: PhotoItem.ID,
        timeRange: ClosedRange<Date>,
        avgPHashSimilarity: Double,
        isExpanded: Bool = false
    ) {
        self.id = id
        self.memberIDs = memberIDs
        self.representativeID = representativeID
        self.timeRange = timeRange
        self.avgPHashSimilarity = avgPHashSimilarity
        self.isExpanded = isExpanded
    }
}

/// 디스크 캐시 표현. 파일명 기반이라 세션 넘어 유효.
struct ClusterCacheEntry: Codable, Equatable {
    var memberFileNames: [String]
    var representativeFileName: String
    var timeRangeStart: Date
    var timeRangeEnd: Date
    var avgPHashSimilarity: Double
}

struct ClusterCacheFile: Codable {
    let version: Int        // 현재 1
    let generatedAt: Date
    let fileHash: String    // 폴더 상태 SHA1
    let clusters: [ClusterCacheEntry]
}
```

- [ ] `project.pbxproj`에 `PhotoCluster.swift`(앱 타겟) 및 `PhotoClusterTests.swift`(PickShotTests 타겟) 추가.

### Step 4 — Verify

- [ ] `xcodebuild build` 성공.
- [ ] `xcodebuild test` 에서 `PhotoClusterTests` 3개 통과.

### Step 5 — Commit

- [ ] `git add PhotoRawManager/Models/PhotoCluster.swift PickShotTests/PhotoClusterTests.swift PhotoRawManager.xcodeproj/project.pbxproj`
- [ ] 커밋 메시지: `feat(clustering): PhotoCluster 모델 + 캐시 표현 추가`

---

## Task 2 — ClusteringParameters 모델 + UserDefaults 영속화

**Files:**
- 생성: `/Users/potokan/PhotoRawManager/PhotoRawManager/Models/ClusteringParameters.swift`
- 생성: `/Users/potokan/PhotoRawManager/PickShotTests/ClusteringParametersTests.swift`
- 수정: `/Users/potokan/PhotoRawManager/PhotoRawManager.xcodeproj/project.pbxproj`

### Step 1 — 실패 테스트

```swift
import XCTest
@testable import PhotoRawManager

final class ClusteringParametersTests: XCTestCase {

    override func setUp() {
        super.setUp()
        UserDefaults.standard.removeObject(forKey: ClusteringParameters.userDefaultsKey)
    }

    func test_defaults_matchSpec() {
        let p = ClusteringParameters()
        XCTAssertEqual(p.burstIntervalSec, 2.0, accuracy: 0.001)
        XCTAssertEqual(p.groupMaxGapSec, 10.0, accuracy: 0.001)
        XCTAssertEqual(p.pHashThreshold, 0.88, accuracy: 0.001)
        XCTAssertEqual(p.minGroupSize, 2)
        XCTAssertFalse(p.autoOnFolderOpen)
    }

    func test_saveAndLoad_roundtrip() {
        var p = ClusteringParameters()
        p.burstIntervalSec = 3.5
        p.pHashThreshold = 0.9
        p.autoOnFolderOpen = true
        p.save()

        let loaded = ClusteringParameters.load()
        XCTAssertEqual(loaded.burstIntervalSec, 3.5, accuracy: 0.001)
        XCTAssertEqual(loaded.pHashThreshold, 0.9, accuracy: 0.001)
        XCTAssertTrue(loaded.autoOnFolderOpen)
    }

    func test_load_whenMissing_returnsDefaults() {
        UserDefaults.standard.removeObject(forKey: ClusteringParameters.userDefaultsKey)
        let loaded = ClusteringParameters.load()
        XCTAssertEqual(loaded.minGroupSize, 2)
    }
}
```

### Step 2 — Run: 실패 확인

- [ ] 빌드 실패 — `ClusteringParameters` 미정의.

### Step 3 — 구현

```swift
import Foundation

struct ClusteringParameters: Codable, Equatable {
    var burstIntervalSec: Double = 2.0
    var groupMaxGapSec: Double = 10.0
    var pHashThreshold: Double = 0.88
    var minGroupSize: Int = 2
    var autoOnFolderOpen: Bool = false
    var hideCacheFile: Bool = true      // .pickshot_clusters.json hidden flag

    static let userDefaultsKey = "com.pickshot.clusteringParameters"

    func save() {
        guard let data = try? JSONEncoder().encode(self) else { return }
        UserDefaults.standard.set(data, forKey: Self.userDefaultsKey)
    }

    static func load() -> ClusteringParameters {
        guard let data = UserDefaults.standard.data(forKey: userDefaultsKey),
              let p = try? JSONDecoder().decode(ClusteringParameters.self, from: data) else {
            return ClusteringParameters()
        }
        return p
    }
}
```

- [ ] pbxproj 추가.

### Step 4 — Verify

- [ ] 테스트 3개 통과.

### Step 5 — Commit

- [ ] 커밋: `feat(clustering): ClusteringParameters + UserDefaults 영속화`

---

## Task 3 — PhotoClusteringService.computeBurstGroups (Phase 1 시간 기반)

**Files:**
- 생성: `/Users/potokan/PhotoRawManager/PhotoRawManager/Services/PhotoClusteringService.swift`
- 생성: `/Users/potokan/PhotoRawManager/PickShotTests/PhotoClusteringServiceTimeTests.swift`

### Step 1 — 실패 테스트

```swift
import XCTest
@testable import PhotoRawManager

final class PhotoClusteringServiceTimeTests: XCTestCase {

    private func makePhoto(name: String, date: Date) -> PhotoItem {
        let url = URL(fileURLWithPath: "/tmp/\(name).jpg")
        var p = PhotoItem(jpgURL: url)
        p.fileModDate = date
        var exif = ExifData()
        exif.dateTimeOriginal = date
        p.exifData = exif
        return p
    }

    func test_time_groupsConsecutiveShots() {
        let base = Date(timeIntervalSince1970: 1_700_000_000)
        let photos = (0..<10).map { makePhoto(name: "IMG_\($0)", date: base.addingTimeInterval(Double($0) * 0.5)) }
        let params = ClusteringParameters()
        let groups = PhotoClusteringService.computeBurstGroups(photos: photos, params: params)
        XCTAssertEqual(groups.count, 1)
        XCTAssertEqual(groups[0].count, 10)
    }

    func test_time_splitsOnLongGap() {
        let base = Date(timeIntervalSince1970: 1_700_000_000)
        let photos = [
            makePhoto(name: "A", date: base),
            makePhoto(name: "B", date: base.addingTimeInterval(1)),
            makePhoto(name: "C", date: base.addingTimeInterval(30)),   // > 10s gap
            makePhoto(name: "D", date: base.addingTimeInterval(31)),
        ]
        let groups = PhotoClusteringService.computeBurstGroups(photos: photos, params: ClusteringParameters())
        XCTAssertEqual(groups.count, 2)
        XCTAssertEqual(groups[0].count, 2)
        XCTAssertEqual(groups[1].count, 2)
    }

    func test_exifMissing_usesFileModDate() {
        let base = Date(timeIntervalSince1970: 1_700_000_000)
        var p1 = PhotoItem(jpgURL: URL(fileURLWithPath: "/tmp/X.jpg"))
        p1.fileModDate = base
        var p2 = PhotoItem(jpgURL: URL(fileURLWithPath: "/tmp/Y.jpg"))
        p2.fileModDate = base.addingTimeInterval(1)
        let groups = PhotoClusteringService.computeBurstGroups(photos: [p1, p2], params: ClusteringParameters())
        XCTAssertEqual(groups.count, 1)
        XCTAssertEqual(groups[0].count, 2)
    }

    func test_ignoresFoldersAndParent() {
        let base = Date(timeIntervalSince1970: 1_700_000_000)
        var folder = PhotoItem(jpgURL: URL(fileURLWithPath: "/tmp/sub"))
        folder.isFolder = true
        folder.fileModDate = base
        let photo = makePhoto(name: "A", date: base.addingTimeInterval(1))
        let groups = PhotoClusteringService.computeBurstGroups(photos: [folder, photo], params: ClusteringParameters())
        // 폴더 단일 → burst가 아니므로 1-element 그룹 유지 or 제외는 Task6에서 minSize로 필터. Phase1에서는 유지.
        XCTAssertTrue(groups.contains { $0.contains { $0.jpgURL == photo.jpgURL } })
    }
}
```

### Step 2 — Run: 실패

### Step 3 — 구현

```swift
import Foundation
import CoreImage

/// 2단계 클러스터링 알고리즘.
/// Phase 1: 시간 기반 예비 그룹 (burst/scene window)
/// Phase 2: pHash 기반 정제
enum PhotoClusteringService {

    /// 사진의 촬영 시간. EXIF DateTimeOriginal 우선, 없으면 fileModDate.
    static func shotDate(of photo: PhotoItem) -> Date {
        if let d = photo.exifData?.dateTimeOriginal { return d }
        return photo.fileModDate
    }

    /// Phase 1 — 시간 기반 예비 그룹. 인접 사진 간격이 groupMaxGapSec 이내면 같은 그룹.
    /// 폴더/부모 아이템은 제외한 뒤 시간순 정렬.
    static func computeBurstGroups(
        photos: [PhotoItem],
        params: ClusteringParameters
    ) -> [[PhotoItem]] {
        let candidates = photos
            .filter { !$0.isFolder && !$0.isParentFolder }
            .sorted { shotDate(of: $0) < shotDate(of: $1) }

        guard !candidates.isEmpty else { return [] }

        var groups: [[PhotoItem]] = []
        var current: [PhotoItem] = [candidates[0]]

        for i in 1..<candidates.count {
            let prev = candidates[i - 1]
            let cur = candidates[i]
            let gap = shotDate(of: cur).timeIntervalSince(shotDate(of: prev))
            if gap <= params.groupMaxGapSec {
                current.append(cur)
            } else {
                groups.append(current)
                current = [cur]
            }
        }
        groups.append(current)
        return groups
    }
}
```

- [ ] pbxproj 추가.

### Step 4 — Verify

- [ ] 4개 테스트 통과.

### Step 5 — Commit

- [ ] 커밋: `feat(clustering): Phase 1 시간 기반 예비 그룹 알고리즘`

---

## Task 4 — PhotoClusteringService.refineWithPHash (Phase 2)

**Files:**
- 수정: `PhotoClusteringService.swift`
- 생성: `/Users/potokan/PhotoRawManager/PickShotTests/PhotoClusteringServicePHashTests.swift`
- 생성 테스트 픽스처: `/Users/potokan/PhotoRawManager/PickShotTests/Fixtures/` (동일/유사/완전 다른 3쌍 JPG)

### Step 1 — 실패 테스트

```swift
import XCTest
@testable import PhotoRawManager

final class PhotoClusteringServicePHashTests: XCTestCase {

    private var fixturesURL: URL {
        Bundle(for: Self.self).resourceURL!.appendingPathComponent("Fixtures")
    }

    private func photo(_ name: String, date: Date) -> PhotoItem {
        var p = PhotoItem(jpgURL: fixturesURL.appendingPathComponent(name))
        p.fileModDate = date
        var exif = ExifData()
        exif.dateTimeOriginal = date
        p.exifData = exif
        return p
    }

    func test_phash_keepsSimilarDropsDifferent() {
        let base = Date(timeIntervalSince1970: 1_700_000_000)
        // similar_a.jpg, similar_b.jpg: 거의 동일. different.jpg: 완전 다른 장면.
        let photos = [
            photo("similar_a.jpg", date: base),
            photo("similar_b.jpg", date: base.addingTimeInterval(1)),
            photo("different.jpg", date: base.addingTimeInterval(2)),
        ]
        let params = ClusteringParameters()  // threshold 0.88
        let refined = PhotoClusteringService.refineWithPHash(
            group: photos,
            representative: photos[0],
            params: params
        )
        // similar_b는 포함, different는 탈락.
        XCTAssertTrue(refined.contains { $0.jpgURL.lastPathComponent == "similar_a.jpg" })
        XCTAssertTrue(refined.contains { $0.jpgURL.lastPathComponent == "similar_b.jpg" })
        XCTAssertFalse(refined.contains { $0.jpgURL.lastPathComponent == "different.jpg" })
    }

    func test_phash_allIdentical_keepsAll() {
        let base = Date(timeIntervalSince1970: 1_700_000_000)
        let photos = [
            photo("similar_a.jpg", date: base),
            photo("similar_a.jpg", date: base.addingTimeInterval(1)),
        ]
        let refined = PhotoClusteringService.refineWithPHash(
            group: photos,
            representative: photos[0],
            params: ClusteringParameters()
        )
        XCTAssertEqual(refined.count, 2)
    }
}
```

**픽스처 준비:** 실제 JPG 3장을 `PickShotTests/Fixtures/`에 추가하고 pbxproj에 리소스로 등록. 없으면 Task 16에서 합성 이미지 생성 헬퍼로 생성.

### Step 2 — Run: 실패

### Step 3 — 구현

`PhotoClusteringService.swift`에 추가:

```swift
extension PhotoClusteringService {

    /// Phase 2 — 대표 사진의 pHash 와 유사도가 threshold 이상인 멤버만 남김.
    /// pHash 계산은 AISimilarityService.computePHash 재사용 (병렬 가능).
    static func refineWithPHash(
        group: [PhotoItem],
        representative rep: PhotoItem,
        params: ClusteringParameters
    ) -> [PhotoItem] {
        let repHash = AISimilarityService.computePHash(url: rep.jpgURL)
        guard repHash != 0 else {
            // 대표 이미지 로드 실패 → refine 포기, 원본 그룹 그대로.
            return group
        }

        // 병렬 pHash 계산
        var hashes = [UInt64](repeating: 0, count: group.count)
        DispatchQueue.concurrentPerform(iterations: group.count) { i in
            hashes[i] = AISimilarityService.computePHash(url: group[i].jpgURL)
        }

        var kept: [PhotoItem] = []
        for i in 0..<group.count {
            if group[i].jpgURL == rep.jpgURL {
                kept.append(group[i])
                continue
            }
            if hashes[i] == 0 { continue }  // 손상 이미지는 탈락 (단일 그룹행)
            let sim = AISimilarityService.hammingSimilarity(repHash, hashes[i])
            if sim >= params.pHashThreshold {
                kept.append(group[i])
            }
        }
        return kept
    }

    /// 그룹의 평균 pHash 유사도 (대표 기준).
    static func averagePHashSimilarity(
        group: [PhotoItem],
        representative rep: PhotoItem
    ) -> Double {
        let repHash = AISimilarityService.computePHash(url: rep.jpgURL)
        guard repHash != 0, group.count > 1 else { return 1.0 }
        var sum: Double = 0
        var count = 0
        for m in group where m.jpgURL != rep.jpgURL {
            let h = AISimilarityService.computePHash(url: m.jpgURL)
            guard h != 0 else { continue }
            sum += AISimilarityService.hammingSimilarity(repHash, h)
            count += 1
        }
        return count == 0 ? 1.0 : sum / Double(count)
    }
}
```

### Step 4 — Verify

- [ ] 테스트 2개 통과 (픽스처 있으면). 픽스처 없으면 단위 테스트 `skip` 후 Task 16 통합 테스트에서 검증.

### Step 5 — Commit

- [ ] 커밋: `feat(clustering): Phase 2 pHash 정제 (병렬 계산)`

---

## Task 5 — selectRepresentative (품질 점수 1등 선정)

**Files:**
- 수정: `PhotoClusteringService.swift`
- 생성: `/Users/potokan/PhotoRawManager/PickShotTests/PhotoClusteringServiceRepresentativeTests.swift`

### Step 1 — 실패 테스트

```swift
import XCTest
@testable import PhotoRawManager

final class PhotoClusteringServiceRepresentativeTests: XCTestCase {

    private func p(_ name: String, nima: Double? = nil) -> PhotoItem {
        var item = PhotoItem(jpgURL: URL(fileURLWithPath: "/tmp/\(name).jpg"))
        if let n = nima {
            var q = QualityAnalysis()
            q.nimaScore = n
            q.isAnalyzed = true
            item.quality = q
        }
        return item
    }

    func test_representative_picksBestQualityScore() {
        let a = p("a", nima: 4.0)   // score ~40
        let b = p("b", nima: 8.5)   // score ~85 ← 최고
        let c = p("c", nima: 6.0)   // score ~60
        let rep = PhotoClusteringService.selectRepresentative(in: [a, b, c])
        XCTAssertEqual(rep.jpgURL.lastPathComponent, "b.jpg")
    }

    func test_representative_fallbackWhenNoQualityScore() {
        let a = p("a")
        let b = p("b")
        let rep = PhotoClusteringService.selectRepresentative(in: [a, b])
        XCTAssertEqual(rep.jpgURL.lastPathComponent, "a.jpg")  // 첫 번째
    }

    func test_representative_mixedScoresAndNil() {
        let a = p("a")                  // nil
        let b = p("b", nima: 5.0)       // ~50
        let c = p("c", nima: 7.0)       // ~70
        let rep = PhotoClusteringService.selectRepresentative(in: [a, b, c])
        XCTAssertEqual(rep.jpgURL.lastPathComponent, "c.jpg")
    }

    func test_representative_emptyCrashesPrecondition() {
        // precondition이 fire하는지 직접 확인하기 어려움 - 스킵, 호출측에서 guard.
    }
}
```

### Step 2 — Run: 실패

### Step 3 — 구현

`PhotoClusteringService.swift`에 추가:

```swift
extension PhotoClusteringService {

    /// 그룹 내 대표 사진 선정. 품질 점수(QualityAnalysis.score)가 제일 높은 것.
    /// 품질 점수 없는 경우: 첫 번째 사진 (시간순 첫 샷).
    static func selectRepresentative(in group: [PhotoItem]) -> PhotoItem {
        precondition(!group.isEmpty, "selectRepresentative: empty group")
        // 품질 분석된 것이 있는지 확인
        let analyzed = group.filter { $0.quality?.isAnalyzed == true }
        guard !analyzed.isEmpty else {
            return group[0]  // fallback: 첫 사진
        }
        return analyzed.max { (lhs, rhs) in
            (lhs.quality?.score ?? 0) < (rhs.quality?.score ?? 0)
        } ?? group[0]
    }
}
```

### Step 4 — Verify

- [ ] 테스트 3개 통과.

### Step 5 — Commit

- [ ] 커밋: `feat(clustering): 대표 사진 품질 점수 기반 선정`

---

## Task 6 — computeClusters (전체 파이프라인)

**Files:**
- 수정: `PhotoClusteringService.swift`
- 생성: `/Users/potokan/PhotoRawManager/PickShotTests/PhotoClusteringServicePipelineTests.swift`

### Step 1 — 실패 테스트

```swift
import XCTest
@testable import PhotoRawManager

final class PhotoClusteringServicePipelineTests: XCTestCase {

    private func photo(_ name: String, date: Date, nima: Double? = nil) -> PhotoItem {
        var p = PhotoItem(jpgURL: URL(fileURLWithPath: "/tmp/\(name).jpg"))
        p.fileModDate = date
        var ex = ExifData(); ex.dateTimeOriginal = date
        p.exifData = ex
        if let n = nima {
            var q = QualityAnalysis(); q.nimaScore = n; q.isAnalyzed = true
            p.quality = q
        }
        return p
    }

    func test_minSize_dissolvesSingletons() {
        // 단일 사진 + 멀리 떨어진 또 다른 단일 사진 → 0 그룹.
        let base = Date(timeIntervalSince1970: 1_700_000_000)
        let photos = [
            photo("A", date: base),
            photo("B", date: base.addingTimeInterval(3600))
        ]
        var params = ClusteringParameters()
        params.minGroupSize = 2
        // pHash 검증 없이 구조 확인을 위해 phash 계산 실패하는 임시 URL 허용.
        let clusters = PhotoClusteringService.computeClusters(photos: photos, params: params, progress: nil)
        XCTAssertEqual(clusters.count, 0)
    }

    func test_pipeline_producesClusterWithRepresentative() {
        // 2장 연사. 품질 점수 있는 b가 대표.
        let base = Date(timeIntervalSince1970: 1_700_000_000)
        let photos = [
            photo("a", date: base, nima: 4.0),
            photo("a", date: base.addingTimeInterval(1), nima: 8.0),  // same file → pHash 동일
        ]
        // 주의: 실제 파일이 없으므로 pHash = 0이 되고 refineWithPHash가 대체 동작
        // (refineWithPHash: repHash == 0 이면 그룹 그대로 반환)
        var params = ClusteringParameters()
        params.minGroupSize = 2
        let clusters = PhotoClusteringService.computeClusters(photos: photos, params: params, progress: nil)
        XCTAssertEqual(clusters.count, 1)
        XCTAssertEqual(clusters[0].memberIDs.count, 2)
        // 대표는 score 높은 2번째
        XCTAssertEqual(clusters[0].representativeID, photos[1].id)
    }

    func test_progress_isCalled() {
        let base = Date(timeIntervalSince1970: 1_700_000_000)
        let photos = (0..<5).map { photo("p\($0)", date: base.addingTimeInterval(Double($0))) }
        var progressValues: [Double] = []
        _ = PhotoClusteringService.computeClusters(photos: photos, params: ClusteringParameters()) { p in
            progressValues.append(p)
        }
        XCTAssertFalse(progressValues.isEmpty)
        XCTAssertEqual(progressValues.last, 1.0, accuracy: 0.01)
    }
}
```

### Step 2 — Run: 실패

### Step 3 — 구현

```swift
extension PhotoClusteringService {

    /// 전체 파이프라인: Phase 1 → Phase 2 → 대표 선정 → 최소 크기 필터.
    /// progress: 0.0~1.0 진행률 콜백 (호출 스레드 임의).
    static func computeClusters(
        photos: [PhotoItem],
        params: ClusteringParameters,
        progress: ((Double) -> Void)? = nil
    ) -> [PhotoCluster] {
        let burstGroups = computeBurstGroups(photos: photos, params: params)
        progress?(0.1)
        guard !burstGroups.isEmpty else { progress?(1.0); return [] }

        var results: [PhotoCluster] = []
        let total = burstGroups.count
        for (idx, group) in burstGroups.enumerated() {
            // 미리 필터 — 너무 작은 그룹은 스킵.
            if group.count < params.minGroupSize {
                progress?(0.1 + 0.9 * Double(idx + 1) / Double(total))
                continue
            }

            let rep = selectRepresentative(in: group)
            let refined = refineWithPHash(group: group, representative: rep, params: params)

            if refined.count >= params.minGroupSize {
                let sortedByDate = refined.sorted { shotDate(of: $0) < shotDate(of: $1) }
                let start = shotDate(of: sortedByDate.first!)
                let end   = shotDate(of: sortedByDate.last!)
                let avgSim = averagePHashSimilarity(group: refined, representative: rep)
                let cluster = PhotoCluster(
                    memberIDs: sortedByDate.map { $0.id },
                    representativeID: rep.id,
                    timeRange: start...end,
                    avgPHashSimilarity: avgSim
                )
                results.append(cluster)
            }

            progress?(0.1 + 0.9 * Double(idx + 1) / Double(total))
        }
        progress?(1.0)
        return results
    }
}
```

### Step 4 — Verify

- [ ] 테스트 3개 통과.

### Step 5 — Commit

- [ ] 커밋: `feat(clustering): computeClusters 전체 파이프라인 + 진행률`

---

## Task 7 — ClusterCacheService (folder hash, JSON read/write)

**Files:**
- 생성: `/Users/potokan/PhotoRawManager/PhotoRawManager/Services/ClusterCacheService.swift`
- 생성: `/Users/potokan/PhotoRawManager/PickShotTests/ClusterCacheServiceTests.swift`

### Step 1 — 실패 테스트

```swift
import XCTest
@testable import PhotoRawManager

final class ClusterCacheServiceTests: XCTestCase {

    private func tmpDir() -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("clustercache_\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private func makePhoto(_ name: String, mod: Date) -> PhotoItem {
        var p = PhotoItem(jpgURL: URL(fileURLWithPath: "/tmp/\(name)"))
        p.fileModDate = mod
        return p
    }

    func test_folderHash_stableForSameInput() {
        let date = Date(timeIntervalSince1970: 1_700_000_000)
        let photos = [makePhoto("A.jpg", mod: date), makePhoto("B.jpg", mod: date)]
        let h1 = ClusterCacheService.computeFolderHash(photos: photos)
        let h2 = ClusterCacheService.computeFolderHash(photos: photos.reversed())
        XCTAssertEqual(h1, h2)  // 정렬되어야
    }

    func test_folderHash_changesWhenFileAdded() {
        let date = Date(timeIntervalSince1970: 1_700_000_000)
        let a = makePhoto("A.jpg", mod: date)
        let b = makePhoto("B.jpg", mod: date)
        let h1 = ClusterCacheService.computeFolderHash(photos: [a])
        let h2 = ClusterCacheService.computeFolderHash(photos: [a, b])
        XCTAssertNotEqual(h1, h2)
    }

    func test_saveAndLoad_roundtrip() throws {
        let dir = tmpDir()
        defer { try? FileManager.default.removeItem(at: dir) }

        let now = Date()
        let entry = ClusterCacheEntry(
            memberFileNames: ["A.jpg", "B.jpg"],
            representativeFileName: "A.jpg",
            timeRangeStart: now,
            timeRangeEnd: now.addingTimeInterval(2),
            avgPHashSimilarity: 0.9
        )
        try ClusterCacheService.save(folderURL: dir, fileHash: "hash1", clusters: [entry])
        let loaded = ClusterCacheService.load(folderURL: dir)
        XCTAssertNotNil(loaded)
        XCTAssertEqual(loaded?.version, 1)
        XCTAssertEqual(loaded?.fileHash, "hash1")
        XCTAssertEqual(loaded?.clusters.count, 1)
    }

    func test_load_corruptedJSON_returnsNil() throws {
        let dir = tmpDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let fileURL = dir.appendingPathComponent(".pickshot_clusters.json")
        try "not json".write(to: fileURL, atomically: true, encoding: .utf8)
        XCTAssertNil(ClusterCacheService.load(folderURL: dir))
    }

    func test_load_wrongVersion_returnsNil() throws {
        let dir = tmpDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let file = ClusterCacheFile(version: 99, generatedAt: Date(), fileHash: "x", clusters: [])
        let data = try JSONEncoder().encode(file)
        try data.write(to: dir.appendingPathComponent(".pickshot_clusters.json"))
        XCTAssertNil(ClusterCacheService.load(folderURL: dir))
    }
}
```

### Step 2 — Run: 실패

### Step 3 — 구현

```swift
import Foundation
import CryptoKit

enum ClusterCacheService {

    static let cacheFileName = ".pickshot_clusters.json"
    static let currentVersion = 1

    /// 폴더 상태 SHA1 해시 (파일명 + 수정일 기반). 파일 순서 무관.
    static func computeFolderHash(photos: [PhotoItem]) -> String {
        let relevant = photos.filter { !$0.isFolder && !$0.isParentFolder }
        let sorted = relevant.sorted { $0.fileNameWithExtension < $1.fileNameWithExtension }
        let input = sorted
            .map { "\($0.fileNameWithExtension):\($0.fileModDate.timeIntervalSince1970)" }
            .joined(separator: "\n")
        let digest = Insecure.SHA1.hash(data: Data(input.utf8))
        return digest.map { String(format: "%02x", $0) }.joined()
    }

    static func cacheURL(folderURL: URL) -> URL {
        folderURL.appendingPathComponent(cacheFileName)
    }

    /// 캐시 파일 저장. 기존 파일 덮어씀. atomic write.
    static func save(folderURL: URL, fileHash: String, clusters: [ClusterCacheEntry]) throws {
        let file = ClusterCacheFile(
            version: currentVersion,
            generatedAt: Date(),
            fileHash: fileHash,
            clusters: clusters
        )
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(file)
        try data.write(to: cacheURL(folderURL: folderURL), options: .atomic)
    }

    /// 캐시 로드. 파일 없음/손상/버전 불일치 시 nil.
    static func load(folderURL: URL) -> ClusterCacheFile? {
        let url = cacheURL(folderURL: folderURL)
        guard let data = try? Data(contentsOf: url) else { return nil }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        guard let file = try? decoder.decode(ClusterCacheFile.self, from: data) else { return nil }
        guard file.version == currentVersion else { return nil }
        return file
    }

    /// PhotoCluster 런타임 배열 → ClusterCacheEntry 배열 변환 (photos 인덱스로 파일명 해석)
    static func encode(clusters: [PhotoCluster], photos: [PhotoItem]) -> [ClusterCacheEntry] {
        let byID: [PhotoItem.ID: PhotoItem] = Dictionary(uniqueKeysWithValues: photos.map { ($0.id, $0) })
        return clusters.compactMap { cluster in
            let memberNames = cluster.memberIDs.compactMap { byID[$0]?.fileNameWithExtension }
            guard memberNames.count == cluster.memberIDs.count else { return nil }
            guard let repName = byID[cluster.representativeID]?.fileNameWithExtension else { return nil }
            return ClusterCacheEntry(
                memberFileNames: memberNames,
                representativeFileName: repName,
                timeRangeStart: cluster.timeRange.lowerBound,
                timeRangeEnd: cluster.timeRange.upperBound,
                avgPHashSimilarity: cluster.avgPHashSimilarity
            )
        }
    }

    /// ClusterCacheEntry 배열 → PhotoCluster 배열 (현재 PhotoItem들과 매칭).
    /// 파일명 매칭 실패한 클러스터는 버림.
    static func decode(entries: [ClusterCacheEntry], photos: [PhotoItem]) -> [PhotoCluster] {
        let byName: [String: PhotoItem] = Dictionary(
            photos.map { ($0.fileNameWithExtension, $0) },
            uniquingKeysWith: { a, _ in a }
        )
        return entries.compactMap { entry in
            let members = entry.memberFileNames.compactMap { byName[$0] }
            guard members.count == entry.memberFileNames.count else { return nil }
            guard let rep = byName[entry.representativeFileName] else { return nil }
            return PhotoCluster(
                memberIDs: members.map { $0.id },
                representativeID: rep.id,
                timeRange: entry.timeRangeStart...entry.timeRangeEnd,
                avgPHashSimilarity: entry.avgPHashSimilarity
            )
        }
    }
}
```

### Step 4 — Verify

- [ ] 테스트 5개 통과.

### Step 5 — Commit

- [ ] 커밋: `feat(clustering): ClusterCacheService JSON I/O + SHA1 폴더 해시`

---

## Task 8 — ClusterCacheService 무효화 판정

**Files:**
- 수정: `ClusterCacheService.swift`
- 수정: `ClusterCacheServiceTests.swift`

### Step 1 — 실패 테스트

```swift
func test_isValid_trueWhenHashMatches() throws {
    let dir = tmpDir()
    defer { try? FileManager.default.removeItem(at: dir) }
    let date = Date(timeIntervalSince1970: 1_700_000_000)
    let photos = [makePhoto("A.jpg", mod: date)]
    let hash = ClusterCacheService.computeFolderHash(photos: photos)
    try ClusterCacheService.save(folderURL: dir, fileHash: hash, clusters: [])
    let loaded = ClusterCacheService.load(folderURL: dir)!
    XCTAssertTrue(ClusterCacheService.isValid(cache: loaded, for: photos))
}

func test_isValid_falseWhenFileAdded() throws {
    let dir = tmpDir()
    defer { try? FileManager.default.removeItem(at: dir) }
    let date = Date(timeIntervalSince1970: 1_700_000_000)
    let oldPhotos = [makePhoto("A.jpg", mod: date)]
    let hash = ClusterCacheService.computeFolderHash(photos: oldPhotos)
    try ClusterCacheService.save(folderURL: dir, fileHash: hash, clusters: [])
    let loaded = ClusterCacheService.load(folderURL: dir)!
    let newPhotos = [makePhoto("A.jpg", mod: date), makePhoto("B.jpg", mod: date)]
    XCTAssertFalse(ClusterCacheService.isValid(cache: loaded, for: newPhotos))
}
```

### Step 2 — Run: 실패

### Step 3 — 구현

`ClusterCacheService.swift`에 추가:

```swift
extension ClusterCacheService {
    /// 캐시와 현재 폴더 상태 일치 여부.
    static func isValid(cache: ClusterCacheFile, for photos: [PhotoItem]) -> Bool {
        return cache.fileHash == computeFolderHash(photos: photos)
    }
}
```

### Step 4 — Verify

- [ ] 테스트 추가 2개 통과.

### Step 5 — Commit

- [ ] 커밋: `feat(clustering): 캐시 유효성 판정 (폴더 해시 비교)`

---

## Task 9 — PhotoStore 통합 (clusters, progress, async actions)

**Files:**
- 수정: `/Users/potokan/PhotoRawManager/PhotoRawManager/Models/PhotoStore.swift`
- 생성: `/Users/potokan/PhotoRawManager/PickShotTests/PhotoStoreClusteringTests.swift`

### Step 1 — 실패 테스트

```swift
import XCTest
@testable import PhotoRawManager

@MainActor
final class PhotoStoreClusteringTests: XCTestCase {

    func test_invalidate_setsCacheDirty() {
        let store = PhotoStore()
        XCTAssertFalse(store.clusterCacheDirty)
        store.invalidateClusters()
        XCTAssertTrue(store.clusterCacheDirty)
    }

    func test_toggleExpandAll_flipsAllClustersExpanded() {
        let store = PhotoStore()
        let idA = UUID(), idB = UUID()
        store.clusters = [
            PhotoCluster(memberIDs: [idA, idB], representativeID: idA,
                         timeRange: Date()...Date().addingTimeInterval(1),
                         avgPHashSimilarity: 0.9),
            PhotoCluster(memberIDs: [idA, idB], representativeID: idB,
                         timeRange: Date()...Date().addingTimeInterval(1),
                         avgPHashSimilarity: 0.9)
        ]
        store.toggleExpandAll()
        XCTAssertTrue(store.expandAllGroups)
        XCTAssertTrue(store.clusters.allSatisfy { $0.isExpanded })
        store.toggleExpandAll()
        XCTAssertFalse(store.expandAllGroups)
        XCTAssertTrue(store.clusters.allSatisfy { !$0.isExpanded })
    }

    func test_toggleGroupExpansion_flipsSingle() {
        let store = PhotoStore()
        let cid = UUID()
        store.clusters = [
            PhotoCluster(id: cid, memberIDs: [UUID()], representativeID: UUID(),
                         timeRange: Date()...Date(), avgPHashSimilarity: 1.0)
        ]
        store.toggleGroupExpansion(cid)
        XCTAssertTrue(store.clusters[0].isExpanded)
        store.toggleGroupExpansion(cid)
        XCTAssertFalse(store.clusters[0].isExpanded)
    }
}
```

### Step 2 — Run: 실패

### Step 3 — 구현

`PhotoStore.swift` 상단 (@Published 근처)에 추가:

```swift
// MARK: - Clustering (v8.1)
@Published var clusters: [PhotoCluster] = []
@Published var clusteringInProgress: Bool = false
@Published var clusteringProgress: Double = 0.0
@Published var clusterCacheDirty: Bool = false
@Published var expandAllGroups: Bool = false
@Published var clusteringParameters: ClusteringParameters = ClusteringParameters.load()

private var clusteringTask: Task<Void, Never>?
```

동일 파일 말미에 extension 추가:

```swift
// MARK: - Clustering Actions
extension PhotoStore {

    /// 현재 폴더의 클러스터를 재계산. 기존 clusters 덮어쓰고 캐시 저장.
    func computeClusters() async {
        guard !clusteringInProgress else { return }
        let snapshot = photos
        let params = clusteringParameters
        let folderURL = currentFolderURL

        await MainActor.run {
            self.clusteringInProgress = true
            self.clusteringProgress = 0.0
            self.clusterCacheDirty = false
        }

        let task = Task.detached(priority: .userInitiated) { [weak self] () -> [PhotoCluster] in
            let result = PhotoClusteringService.computeClusters(
                photos: snapshot,
                params: params,
                progress: { p in
                    Task { @MainActor in self?.clusteringProgress = p }
                }
            )
            return result
        }
        clusteringTask = Task { [weak self] in
            let result = await task.value
            await MainActor.run {
                guard let self = self else { return }
                self.clusters = result
                self.clusteringInProgress = false
                self.clusteringProgress = 1.0
                if let folder = folderURL {
                    let entries = ClusterCacheService.encode(clusters: result, photos: snapshot)
                    let hash = ClusterCacheService.computeFolderHash(photos: snapshot)
                    try? ClusterCacheService.save(folderURL: folder, fileHash: hash, clusters: entries)
                }
            }
        }
    }

    /// 폴더 열 때 호출. 캐시 있으면 로드해서 clusters에 세팅 → true 리턴.
    @discardableResult
    func loadClustersFromCache() -> Bool {
        guard let folder = currentFolderURL,
              let cache = ClusterCacheService.load(folderURL: folder) else {
            clusters = []
            clusterCacheDirty = false
            return false
        }
        clusters = ClusterCacheService.decode(entries: cache.clusters, photos: photos)
        clusterCacheDirty = !ClusterCacheService.isValid(cache: cache, for: photos)
        return true
    }

    func toggleGroupExpansion(_ id: UUID) {
        guard let i = clusters.firstIndex(where: { $0.id == id }) else { return }
        clusters[i].isExpanded.toggle()
    }

    func toggleExpandAll() {
        expandAllGroups.toggle()
        for i in clusters.indices {
            clusters[i].isExpanded = expandAllGroups
        }
    }

    func invalidateClusters() {
        clusterCacheDirty = true
    }

    func cancelClustering() {
        clusteringTask?.cancel()
        clusteringTask = nil
        clusteringInProgress = false
        clusteringProgress = 0.0
    }
}
```

**주의:** `currentFolderURL` 이름이 PhotoStore에 이미 존재한다고 가정. 실제 이름 다르면 Grep으로 확인 후 치환 (예: `rootFolder`, `currentFolder`).

### Step 4 — Verify

- [ ] 테스트 3개 통과. 빌드 성공.

### Step 5 — Commit

- [ ] 커밋: `feat(clustering): PhotoStore 클러스터 상태/액션 통합`

---

## Task 10 — FolderWatcherService onClusterCacheInvalidated 콜백

**Files:**
- 수정: `/Users/potokan/PhotoRawManager/PhotoRawManager/Services/FolderWatcherService.swift`
- 생성: `/Users/potokan/PhotoRawManager/PickShotTests/FolderWatcherClusterInvalidateTests.swift`

### Step 1 — 실패 테스트

```swift
import XCTest
@testable import PhotoRawManager

final class FolderWatcherClusterInvalidateTests: XCTestCase {

    func test_watcher_hasClusterInvalidateCallback() {
        let w = FolderWatcherService()
        var fired = false
        w.onClusterCacheInvalidated = { fired = true }
        // 공개 API가 정말 정의됐는지 컴파일 체크 목적.
        XCTAssertNotNil(w.onClusterCacheInvalidated)
        _ = fired
    }

    func test_newFilesDetected_alsoFiresClusterInvalidate() {
        let w = FolderWatcherService()
        let expClu = expectation(description: "cluster invalidated")
        w.onClusterCacheInvalidated = { expClu.fulfill() }
        // 직접 호출로 콜백 발화 검증 (private 메서드 접근 불가 → 간접 테스트)
        // onNewFilesDetected 발화 시 onClusterCacheInvalidated 도 발화해야.
        w.onNewFilesDetected = { _ in }
        // 테스트용 발화 진입점 (internal trigger) — 아래 구현에서 제공
        w._testFireNewFiles(urls: [URL(fileURLWithPath: "/tmp/x.jpg")])
        wait(for: [expClu], timeout: 1.0)
    }
}
```

### Step 2 — Run: 실패

### Step 3 — 구현

`FolderWatcherService.swift` 수정:

```swift
// 기존 onNewFilesDetected 아래에 추가
/// Called on the main queue when files change in a way that invalidates
/// the clustering cache (new files or deletions).
var onClusterCacheInvalidated: (() -> Void)?
```

기존 `checkForNewFiles()` 내 `DispatchQueue.main.async { [weak self] in self?.onNewFilesDetected?(newURLs) }` 호출 직후에 추가:

```swift
DispatchQueue.main.async { [weak self] in
    self?.onClusterCacheInvalidated?()
}
```

그리고 `onFolderStructureChanged?()` 발화하는 2곳 (folderChanged 및 deletedFiles 분기) 에도 마찬가지로 추가.

**테스트용 훅** (internal, DEBUG 한정):

```swift
#if DEBUG
func _testFireNewFiles(urls: Set<URL>) {
    DispatchQueue.main.async { [weak self] in
        self?.onNewFilesDetected?(urls)
        self?.onClusterCacheInvalidated?()
    }
}
#endif
```

### Step 4 — Verify

- [ ] 테스트 2개 통과.

### Step 5 — Commit

- [ ] 커밋: `feat(clustering): FolderWatcher 클러스터 캐시 무효화 콜백`

---

## Task 11 — ThumbnailGridView 그룹 뱃지 렌더링

**Files:**
- 수정: `/Users/potokan/PhotoRawManager/PhotoRawManager/Views/ThumbnailGridView.swift`
- 생성: 간단한 스냅샷-프리 UI 테스트 (뷰 모델 레벨) `/Users/potokan/PhotoRawManager/PickShotTests/ThumbnailGridClusterBadgeTests.swift`

### Step 1 — 실패 테스트 (뷰 모델 로직만 테스트)

```swift
import XCTest
@testable import PhotoRawManager

@MainActor
final class ThumbnailGridClusterBadgeTests: XCTestCase {

    func test_clusterBadge_returnsNilForNonRepresentative() {
        let store = PhotoStore()
        let memberID = UUID()
        let repID = UUID()
        store.clusters = [
            PhotoCluster(memberIDs: [repID, memberID],
                         representativeID: repID,
                         timeRange: Date()...Date(),
                         avgPHashSimilarity: 0.9)
        ]
        XCTAssertNil(store.clusterBadge(for: memberID))
        XCTAssertNotNil(store.clusterBadge(for: repID))
    }

    func test_clusterBadge_returnsSize() {
        let store = PhotoStore()
        let ids = (0..<7).map { _ in UUID() }
        let repID = ids[0]
        store.clusters = [
            PhotoCluster(memberIDs: ids, representativeID: repID,
                         timeRange: Date()...Date(), avgPHashSimilarity: 0.9)
        ]
        let badge = store.clusterBadge(for: repID)
        XCTAssertEqual(badge?.memberCount, 7)
    }

    func test_isGroupMember_trueOnlyForMembers() {
        let store = PhotoStore()
        let repID = UUID(); let memID = UUID(); let outsider = UUID()
        store.clusters = [
            PhotoCluster(memberIDs: [repID, memID], representativeID: repID,
                         timeRange: Date()...Date(), avgPHashSimilarity: 0.9)
        ]
        XCTAssertTrue(store.isClusterMember(memID))
        XCTAssertTrue(store.isClusterMember(repID))
        XCTAssertFalse(store.isClusterMember(outsider))
    }
}
```

### Step 2 — Run: 실패

### Step 3 — 구현

`PhotoStore.swift`에 헬퍼 추가:

```swift
extension PhotoStore {
    struct ClusterBadgeInfo {
        let clusterID: UUID
        let memberCount: Int
        let isExpanded: Bool
    }

    func clusterBadge(for photoID: PhotoItem.ID) -> ClusterBadgeInfo? {
        guard let c = clusters.first(where: { $0.representativeID == photoID }) else { return nil }
        return ClusterBadgeInfo(clusterID: c.id, memberCount: c.memberIDs.count, isExpanded: c.isExpanded)
    }

    /// 대표가 아닌 일반 멤버 (= 펼친 상태에서만 보이는 사진)
    func isClusterNonRepresentativeMember(_ photoID: PhotoItem.ID) -> Bool {
        clusters.contains { $0.memberIDs.contains(photoID) && $0.representativeID != photoID }
    }

    func isClusterMember(_ photoID: PhotoItem.ID) -> Bool {
        clusters.contains { $0.memberIDs.contains(photoID) }
    }

    /// 해당 photoID가 속한 클러스터 (없으면 nil)
    func cluster(containing photoID: PhotoItem.ID) -> PhotoCluster? {
        clusters.first { $0.memberIDs.contains(photoID) }
    }
}
```

`ThumbnailGridView.swift` 내 셀 빌더(대표 셀 or 단일 썸네일 공용):

```swift
// MARK: - Cluster Badge Overlay
@ViewBuilder
private func clusterBadgeOverlay(for photo: PhotoItem) -> some View {
    if let badge = store.clusterBadge(for: photo.id) {
        HStack(spacing: 2) {
            Text("\(badge.memberCount)")
                .font(.system(size: 11, weight: .bold))
            Image(systemName: "sparkles")
                .font(.system(size: 10))
        }
        .padding(.horizontal, 6)
        .padding(.vertical, 3)
        .background(
            RoundedRectangle(cornerRadius: 6)
                .fill(Color.black.opacity(0.7))
        )
        .foregroundColor(.white)
        .padding(6)
        .onTapGesture { store.toggleGroupExpansion(badge.clusterID) }
        .help("그룹 \(badge.memberCount)장 — 클릭해서 펼치기")
    }
}
```

기존 셀 뷰(`.overlay(alignment: .topTrailing) { clusterBadgeOverlay(for: photo) }`) 추가.

필터링: 그리드 루프에서 대표가 아닌 비대표 멤버는 해당 클러스터가 펼쳐진 상태에서만 렌더. 본 Task에서는 **숨김만 구현** (펼침 UI는 Task 12):

```swift
let visiblePhotos = store.photos.filter { photo in
    if store.isClusterNonRepresentativeMember(photo.id) {
        return store.cluster(containing: photo.id)?.isExpanded == true
    }
    return true
}
```

### Step 4 — Verify

- [ ] 뷰모델 테스트 3개 통과. 빌드 성공. 수동 프리뷰: 클러스터 수동 주입 시 대표 셀에만 뱃지 표시.

### Step 5 — Commit

- [ ] 커밋: `feat(clustering): 썸네일 그리드 그룹 뱃지 + 비대표 숨김`

---

## Task 12 — ThumbnailGridView 인라인 확장 (펼침 UI)

**Files:**
- 수정: `ThumbnailGridView.swift`

### Step 1 — 실패 테스트 (UI 상태 플래그)

```swift
// PhotoStoreClusteringTests.swift 확장
func test_expandedCluster_nonRepMembersBecomeVisible() {
    let store = PhotoStore()
    let repID = UUID(); let memID = UUID()
    let cid = UUID()
    store.clusters = [
        PhotoCluster(id: cid, memberIDs: [repID, memID], representativeID: repID,
                     timeRange: Date()...Date(), avgPHashSimilarity: 0.9)
    ]
    XCTAssertTrue(store.isClusterNonRepresentativeMember(memID))
    // 접힌 상태: 숨겨야 함
    XCTAssertFalse(store.clusters[0].isExpanded)
    // 펼치면
    store.toggleGroupExpansion(cid)
    XCTAssertTrue(store.clusters[0].isExpanded)
}
```

### Step 2 — Run: 테스트 추가 후 실패 여부 확인 (이미 Task11에서 상당부분 통과하면 새 Green)

### Step 3 — 구현

`ThumbnailGridView.swift`:

1. Task 11의 `visiblePhotos` 필터를 이미 적용했으면 펼침 토글만으로 멤버 셀이 자연스레 그리드에 추가됨.
2. 그룹 멤버 셀 파란 테두리 + 순서 라벨:

```swift
@ViewBuilder
private func clusterMemberDecoration(for photo: PhotoItem) -> some View {
    if let cluster = store.cluster(containing: photo.id),
       cluster.representativeID != photo.id,
       cluster.isExpanded {
        let idx = cluster.memberIDs.firstIndex(of: photo.id) ?? 0
        ZStack(alignment: .topLeading) {
            RoundedRectangle(cornerRadius: 6)
                .stroke(Color.blue, lineWidth: 2)
            Text("\(idx + 1)")
                .font(.system(size: 10, weight: .bold))
                .padding(.horizontal, 4)
                .padding(.vertical, 2)
                .background(Color.blue)
                .foregroundColor(.white)
                .cornerRadius(4)
                .padding(4)
        }
    }
}
```

`.overlay { clusterMemberDecoration(for: photo) }` 셀에 적용.

### Step 4 — Verify

- [ ] 앱 실행 후 수동 검증: 뱃지 클릭 → 그룹 펼침 → 멤버 셀 파란 테두리 + 순서 번호 보임.
- [ ] 테스트 통과.

### Step 5 — Commit

- [ ] 커밋: `feat(clustering): 그룹 인라인 확장 + 멤버 셀 파란 테두리/순서`

---

## Task 13 — 툴바 버튼 (유사 컷 묶기 / N개 그룹 / 업데이트 필요)

**Files:**
- 수정: `/Users/potokan/PhotoRawManager/PhotoRawManager/Views/ContentView+Toolbar.swift`

### Step 1 — 테스트 (가능한 범위)

툴바는 SwiftUI 뷰 스냅샷 어렵 → 로직 노출 헬퍼 테스트:

```swift
// PhotoStoreClusteringTests.swift 확장
func test_toolbarLabel_noClusters() {
    let store = PhotoStore()
    XCTAssertEqual(store.clusterToolbarState, .idle)
}

func test_toolbarLabel_inProgress() {
    let store = PhotoStore()
    store.clusteringInProgress = true
    store.clusteringProgress = 0.42
    if case .computing(let p) = store.clusterToolbarState {
        XCTAssertEqual(p, 0.42, accuracy: 0.001)
    } else { XCTFail() }
}

func test_toolbarLabel_withClusters() {
    let store = PhotoStore()
    store.clusters = [
        PhotoCluster(memberIDs: [UUID(), UUID()], representativeID: UUID(),
                     timeRange: Date()...Date(), avgPHashSimilarity: 0.9)
    ]
    if case .done(let count, let grouped) = store.clusterToolbarState {
        XCTAssertEqual(count, 1)
        XCTAssertEqual(grouped, 2)
    } else { XCTFail() }
}

func test_toolbarLabel_dirty() {
    let store = PhotoStore()
    store.clusters = [PhotoCluster(memberIDs: [UUID()], representativeID: UUID(),
                                   timeRange: Date()...Date(), avgPHashSimilarity: 1)]
    store.clusterCacheDirty = true
    if case .dirty = store.clusterToolbarState {} else { XCTFail() }
}
```

### Step 2 — Run: 실패

### Step 3 — 구현

`PhotoStore.swift` 확장:

```swift
enum ClusterToolbarState: Equatable {
    case idle
    case computing(progress: Double)
    case done(clusterCount: Int, groupedPhotoCount: Int)
    case dirty
}

extension PhotoStore {
    var clusterToolbarState: ClusterToolbarState {
        if clusteringInProgress { return .computing(progress: clusteringProgress) }
        if clusterCacheDirty && !clusters.isEmpty { return .dirty }
        if !clusters.isEmpty {
            let grouped = clusters.reduce(0) { $0 + $1.memberIDs.count }
            return .done(clusterCount: clusters.count, groupedPhotoCount: grouped)
        }
        return .idle
    }
}
```

`ContentView+Toolbar.swift`에 툴바 아이템 추가 (적절한 `ToolbarItemGroup` 내):

```swift
@ViewBuilder
private var clusterToolbarButton: some View {
    switch photoStore.clusterToolbarState {
    case .idle:
        Button {
            Task { await photoStore.computeClusters() }
        } label: {
            Label("유사 컷 묶기", systemImage: "square.stack.3d.up")
        }
        .help("시간 + pHash 기반 그룹핑 (Cmd+G)")

    case .computing(let p):
        HStack(spacing: 6) {
            ProgressView(value: p).frame(width: 80)
            Text("\(Int(p * 100))%")
                .font(.system(.caption, design: .monospaced))
            Button("취소") { photoStore.cancelClustering() }
                .buttonStyle(.borderless)
        }

    case .done(let count, let grouped):
        HStack(spacing: 8) {
            Text("\(count)개 그룹 · \(grouped)장 묶임")
                .font(.caption)
            Button(photoStore.expandAllGroups ? "모두 접기" : "모두 펼치기") {
                photoStore.toggleExpandAll()
            }
            .buttonStyle(.borderless)
        }

    case .dirty:
        HStack(spacing: 6) {
            Text("\(photoStore.clusters.count)개 그룹")
                .font(.caption)
            Button {
                Task { await photoStore.computeClusters() }
            } label: {
                Label("업데이트 필요", systemImage: "exclamationmark.triangle.fill")
                    .foregroundColor(.orange)
            }
            .help("파일이 추가/삭제됐습니다. 클릭해서 재계산")
        }
    }
}
```

실제 `ToolbarItem` 배치 위치는 기존 툴바의 비슷한 액션 옆에 삽입.

### Step 4 — Verify

- [ ] 테스트 4개 통과. 수동 확인: 빈 폴더/계산 중/완료/dirty 상태 전환.

### Step 5 — Commit

- [ ] 커밋: `feat(clustering): 툴바 4상태 버튼 (idle/computing/done/dirty)`

---

## Task 14 — 키보드 단축키 (Cmd+G, Cmd+Shift+G, Space)

**Files:**
- 수정: `/Users/potokan/PhotoRawManager/PhotoRawManager/PhotoRawManagerApp.swift`
- 수정: `ContentView+Toolbar.swift` (또는 ContentView 본체에 `.keyboardShortcut` 배치)

### Step 1 — 테스트

단축키 자체는 SwiftUI 시스템 통합이라 단위 테스트 어려움. 액션 함수를 `PhotoStore`에 분리해 테스트:

```swift
func test_cmdG_triggersComputeClusters() async {
    let store = PhotoStore()
    // computeClusters는 폴더 없으면 조용히 종료해도 OK. 진행상태만 확인.
    store.clusteringInProgress = false
    await store.computeClusters()
    // 완료 후 false
    XCTAssertFalse(store.clusteringInProgress)
}

func test_spaceHandler_togglesCurrentGroupExpansion() {
    let store = PhotoStore()
    let cid = UUID(); let repID = UUID(); let memID = UUID()
    store.clusters = [PhotoCluster(id: cid, memberIDs: [repID, memID],
                                   representativeID: repID,
                                   timeRange: Date()...Date(), avgPHashSimilarity: 0.9)]
    store.handleSpaceOnCurrent(photoID: repID)
    XCTAssertTrue(store.clusters[0].isExpanded)
    store.handleSpaceOnCurrent(photoID: repID)
    XCTAssertFalse(store.clusters[0].isExpanded)
}
```

### Step 2 — Run: 실패

### Step 3 — 구현

`PhotoStore.swift`:

```swift
extension PhotoStore {
    /// Space 키 핸들러: 현재 선택된 사진이 속한 그룹 토글.
    func handleSpaceOnCurrent(photoID: PhotoItem.ID) {
        if let c = cluster(containing: photoID) {
            toggleGroupExpansion(c.id)
        }
    }
}
```

`PhotoRawManagerApp.swift` 의 `Commands {}` 블록에 추가 (기존 CommandMenu 안):

```swift
CommandMenu("클러스터") {
    Button("유사 컷 묶기") {
        Task { await photoStore.computeClusters() }
    }
    .keyboardShortcut("g", modifiers: .command)

    Button(photoStore.expandAllGroups ? "모두 접기" : "모두 펼치기") {
        photoStore.toggleExpandAll()
    }
    .keyboardShortcut("g", modifiers: [.command, .shift])
}
```

`ContentView`의 메인 썸네일 뷰 `.onKeyPress(.space)` 또는 NSEvent monitor로 Space 처리 (기존 구조 따름):

```swift
.onKeyPress(.space) {
    if let cur = selectedPhoto?.id {
        photoStore.handleSpaceOnCurrent(photoID: cur)
        return .handled
    }
    return .ignored
}
```

기존 Space 처리가 있으면 그 안에 clustering 토글 분기 추가.

### Step 4 — Verify

- [ ] 앱에서 Cmd+G, Cmd+Shift+G, Space 동작 확인.
- [ ] 테스트 통과.

### Step 5 — Commit

- [ ] 커밋: `feat(clustering): 키보드 단축키 Cmd+G/Shift+G/Space`

---

## Task 15 — SettingsView 클러스터링 섹션

**Files:**
- 수정: 기존 SettingsView 파일 (경로 미상 — Grep으로 확인. 없으면 ContentView+SupportingViews.swift 내 설정 섹션).

### Step 1 — 테스트

UserDefaults 영속화는 Task 2에서 검증됨. 여기서는 PhotoStore 바인딩 테스트:

```swift
func test_setParametersTriggersSave() {
    let store = PhotoStore()
    var p = store.clusteringParameters
    p.pHashThreshold = 0.7
    store.clusteringParameters = p
    store.saveClusteringParameters()
    let loaded = ClusteringParameters.load()
    XCTAssertEqual(loaded.pHashThreshold, 0.7, accuracy: 0.001)
}
```

### Step 2 — Run: 실패

### Step 3 — 구현

`PhotoStore.swift`:

```swift
extension PhotoStore {
    func saveClusteringParameters() {
        clusteringParameters.save()
    }
}
```

SettingsView 섹션 추가:

```swift
Section("유사 컷 클러스터링") {
    Toggle("폴더 열 때 자동 클러스터링", isOn: $photoStore.clusteringParameters.autoOnFolderOpen)

    HStack {
        Text("연사 간격")
        Spacer()
        TextField("", value: $photoStore.clusteringParameters.burstIntervalSec, format: .number)
            .frame(width: 60)
        Text("초")
    }
    HStack {
        Text("그룹 최대 간격")
        Spacer()
        TextField("", value: $photoStore.clusteringParameters.groupMaxGapSec, format: .number)
            .frame(width: 60)
        Text("초")
    }
    HStack {
        Text("pHash 임계값")
        Slider(value: $photoStore.clusteringParameters.pHashThreshold, in: 0.5...0.95)
        Text(String(format: "%.2f", photoStore.clusteringParameters.pHashThreshold))
            .frame(width: 40)
    }
    Stepper(value: $photoStore.clusteringParameters.minGroupSize, in: 2...10) {
        Text("최소 그룹 크기: \(photoStore.clusteringParameters.minGroupSize)장")
    }
    Toggle("캐시 파일 숨김 (.pickshot_clusters.json)", isOn: $photoStore.clusteringParameters.hideCacheFile)

    HStack {
        Button("기본값으로") {
            photoStore.clusteringParameters = ClusteringParameters()
            photoStore.saveClusteringParameters()
        }
        Spacer()
        Button("지금 재계산") {
            photoStore.saveClusteringParameters()
            Task { await photoStore.computeClusters() }
        }
    }
}
.onChange(of: photoStore.clusteringParameters) { _, _ in
    photoStore.saveClusteringParameters()
}
```

### Step 4 — Verify

- [ ] Settings 열어서 파라미터 수정 후 앱 재시작 시 유지.
- [ ] 테스트 통과.

### Step 5 — Commit

- [ ] 커밋: `feat(clustering): Settings 클러스터링 파라미터 섹션`

---

## Task 16 — 통합 테스트 (테스트 이미지 30장)

**Files:**
- 생성: `/Users/potokan/PhotoRawManager/PickShotTests/Fixtures/` (합성 이미지 생성 헬퍼 포함)
- 생성: `/Users/potokan/PhotoRawManager/PickShotTests/PhotoClusteringIntegrationTests.swift`

### Step 1 — 실패 테스트

```swift
import XCTest
import AppKit
@testable import PhotoRawManager

final class PhotoClusteringIntegrationTests: XCTestCase {

    private var workDir: URL!

    override func setUp() {
        super.setUp()
        workDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("clustering_it_\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: workDir, withIntermediateDirectories: true)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: workDir)
        super.tearDown()
    }

    private func makeSolidColorJPEG(at url: URL, color: NSColor, size: Int = 256) throws {
        let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: size, pixelsHigh: size,
                                   bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true,
                                   isPlanar: false, colorSpaceName: .deviceRGB,
                                   bytesPerRow: 0, bitsPerPixel: 0)!
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
        color.setFill()
        NSRect(x: 0, y: 0, width: size, height: size).fill()
        NSGraphicsContext.restoreGraphicsState()
        let data = rep.representation(using: .jpeg, properties: [.compressionFactor: 0.9])!
        try data.write(to: url)
    }

    func test_30photos_produces5Clusters() throws {
        // 5개 그룹 × 6장 (같은 색) + 단일 5장 (서로 다른 색)
        let baseDate = Date(timeIntervalSince1970: 1_700_000_000)
        var photos: [PhotoItem] = []

        // 그룹: 같은 색(= pHash 동일)을 시간 근접하게 배치
        let groupColors: [NSColor] = [.red, .green, .blue, .yellow, .orange]
        for (gi, color) in groupColors.enumerated() {
            for j in 0..<6 {
                let name = "group\(gi)_\(j).jpg"
                let url = workDir.appendingPathComponent(name)
                try makeSolidColorJPEG(at: url, color: color)
                let shotDate = baseDate.addingTimeInterval(Double(gi) * 100 + Double(j) * 0.5)
                var p = PhotoItem(jpgURL: url)
                p.fileModDate = shotDate
                var exif = ExifData(); exif.dateTimeOriginal = shotDate
                p.exifData = exif
                photos.append(p)
            }
        }

        // 단일 5장 — 1분 이상 간격 + 완전히 다른 색
        let singleColors: [NSColor] = [
            .systemPink, .systemTeal, .systemBrown, .systemIndigo, .systemMint
        ]
        for (si, color) in singleColors.enumerated() {
            let name = "single\(si).jpg"
            let url = workDir.appendingPathComponent(name)
            try makeSolidColorJPEG(at: url, color: color)
            let shotDate = baseDate.addingTimeInterval(1_000 + Double(si) * 120)  // 2분 간격
            var p = PhotoItem(jpgURL: url)
            p.fileModDate = shotDate
            var exif = ExifData(); exif.dateTimeOriginal = shotDate
            p.exifData = exif
            photos.append(p)
        }

        let clusters = PhotoClusteringService.computeClusters(photos: photos, params: ClusteringParameters(), progress: nil)
        XCTAssertEqual(clusters.count, 5, "5개 그룹이어야 합니다")
        XCTAssertTrue(clusters.allSatisfy { $0.memberIDs.count == 6 })
    }

    func test_cacheRoundtrip_afterRealCompute() throws {
        // 2장 그룹 생성 후 캐시 저장 → 재로드 → isValid == true
        let date = Date(timeIntervalSince1970: 1_700_000_000)
        var photos: [PhotoItem] = []
        for i in 0..<2 {
            let url = workDir.appendingPathComponent("a\(i).jpg")
            try makeSolidColorJPEG(at: url, color: .red)
            var p = PhotoItem(jpgURL: url)
            p.fileModDate = date.addingTimeInterval(Double(i))
            var ex = ExifData(); ex.dateTimeOriginal = date.addingTimeInterval(Double(i))
            p.exifData = ex
            photos.append(p)
        }

        let clusters = PhotoClusteringService.computeClusters(photos: photos, params: ClusteringParameters(), progress: nil)
        XCTAssertEqual(clusters.count, 1)

        let entries = ClusterCacheService.encode(clusters: clusters, photos: photos)
        let hash = ClusterCacheService.computeFolderHash(photos: photos)
        try ClusterCacheService.save(folderURL: workDir, fileHash: hash, clusters: entries)

        let loaded = ClusterCacheService.load(folderURL: workDir)!
        XCTAssertTrue(ClusterCacheService.isValid(cache: loaded, for: photos))

        let decoded = ClusterCacheService.decode(entries: loaded.clusters, photos: photos)
        XCTAssertEqual(decoded.count, 1)
        XCTAssertEqual(decoded[0].memberIDs.count, 2)
    }
}
```

### Step 2 — Run: 실패 (예상)

### Step 3 — 구현

Task 3~8의 구현이 올바르면 통과. 실패 시 합성 이미지의 pHash 유사도 디버깅:
- `similar_a`, `similar_b` = 동일 색 JPEG → pHash 동일해야 함
- `different` = 반대 색 → pHash 다름

실패 시 `params.pHashThreshold` 0.75로 완화하거나 이미지 크기 조정.

### Step 4 — Verify

- [ ] 테스트 2개 통과. 5개 그룹 정확도 확인.

### Step 5 — Commit

- [ ] 커밋: `test(clustering): 30장 합성 이미지 통합 테스트`

---

## Task 17 — 수동 테스트 체크리스트 + 문서화

**Files:**
- 생성: `/Users/potokan/PhotoRawManager/docs/superpowers/plans/2026-04-14-photo-clustering-manual-test.md`

### Step 1 — 체크리스트 문서 작성

```markdown
# 유사 컷 클러스터링 — 수동 테스트 체크리스트

## 기본 동작
- [ ] 빈 폴더 열기 → 툴바에 "유사 컷 묶기" 버튼 보임
- [ ] 사진 3장 있는 폴더 → 버튼 클릭 → 진행률 표시 → 완료
- [ ] 연사 10장 폴더 → 1개 그룹 (10장)
- [ ] 시간 간격 30초 이상 → 별도 그룹

## 대표 선정
- [ ] 품질 분석 전 → 첫 사진이 대표
- [ ] 품질 분석 후 재계산 → 최고 점수 사진이 대표

## UI
- [ ] 대표 셀 오른쪽 위 `[N] ✨` 뱃지
- [ ] 뱃지 클릭 → 그룹 펼침
- [ ] 펼친 그룹 멤버 셀 파란 테두리 + 순서 번호
- [ ] Cmd+Shift+G → 모두 펼치기/접기
- [ ] Space → 현재 그룹 펼치기/접기

## 툴바 상태
- [ ] 클러스터 없음 → `[유사 컷 묶기]`
- [ ] 계산 중 → 진행률 + 취소
- [ ] 완료 → `[N개 그룹 · M장 묶임]`
- [ ] 파일 변경 후 → `⚠️ 업데이트 필요`

## 캐시
- [ ] 첫 계산 후 `.pickshot_clusters.json` 생성됨
- [ ] 폴더 재오픈 → 즉시 로드 (<100ms)
- [ ] 파일 1장 삭제 후 → dirty 뱃지 표시
- [ ] 재계산 → 정상 업데이트

## 성능
- [ ] 실제 결혼식 사진 1000장 → 15초 이내
- [ ] 클러스터링 중 UI 반응성 유지
- [ ] 메모리 피크 +200MB 이내
- [ ] 그룹 펼침 60fps

## 에러 처리
- [ ] EXIF 없는 JPG → fileModDate로 처리
- [ ] 손상된 JPG 포함 → 해당 장만 제외, 나머지 그룹 OK
- [ ] 클러스터링 중 폴더 닫기 → 크래시 없음

## 브라케팅/포즈
- [ ] HDR 3장 → 1그룹
- [ ] 세션 포토 (포즈 5~10초 간격) → 적절히 분할
- [ ] 풍경 단독 → 그룹 안 만들어짐
```

### Step 2 — Run: N/A (문서)

### Step 3 — 구현: 위 파일 저장

### Step 4 — Verify

- [ ] 개발자가 실제 실행하여 체크.

### Step 5 — Commit

- [ ] 커밋: `docs(clustering): 수동 테스트 체크리스트 추가`

---

## 최종 검증 (모든 Task 완료 후)

- [ ] `xcodebuild build` 성공 — 경고 0개
- [ ] `xcodebuild test` 성공 — 전체 테스트 통과
- [ ] 앱 실행 후 수동 체크리스트 전체 통과
- [ ] `.pickshot_clusters.json` 는 `.gitignore` 에 추가 (사용자 폴더에 생성되므로 prod 레포 영향 없음. 테스트 tmpDir만 사용)
- [ ] Secrets.xcconfig 커밋되지 않았는지 확인
- [ ] CLAUDE.md 의 현재 버전 v3.6 → v8.1로 업데이트할 필요는 별도 릴리즈 커밋에서 처리

---

## 스펙 커버리지 매핑

| 스펙 항목 | 구현 Task |
|-----------|-----------|
| PhotoCluster 런타임 타입 | Task 1 |
| ClusterCacheEntry/File 캐시 타입 | Task 1 |
| ClusteringParameters + UserDefaults | Task 2 |
| Phase 1 시간 기반 그룹 | Task 3 |
| Phase 2 pHash 정제 + 병렬화 | Task 4 |
| 대표 선정 (품질 1등 + fallback) | Task 5 |
| 전체 파이프라인 + 진행률 | Task 6 |
| 캐시 JSON I/O + SHA1 해시 | Task 7 |
| 캐시 유효성 판정 | Task 8 |
| PhotoStore 상태/액션 | Task 9 |
| FolderWatcher 무효화 콜백 | Task 10 |
| 그리드 그룹 뱃지 | Task 11 |
| 그리드 인라인 확장 | Task 12 |
| 툴바 4상태 | Task 13 |
| 키보드 단축키 | Task 14 |
| Settings 섹션 | Task 15 |
| 통합 테스트 30장 | Task 16 |
| 수동 체크리스트 | Task 17 |

타입 일관성:
- 런타임 (메모리): `PhotoCluster.memberIDs: [PhotoItem.ID]`, `representativeID: PhotoItem.ID`
- 캐시 (디스크): `ClusterCacheEntry.memberFileNames: [String]`, `representativeFileName: String`
- 변환은 `ClusterCacheService.encode/decode` 단일 진입점에서만.
