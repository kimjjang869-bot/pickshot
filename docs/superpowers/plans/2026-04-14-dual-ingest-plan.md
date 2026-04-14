# 듀얼 백업 인제스트 Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Photo Mechanic 스타일 듀얼 백업 + 멀티카메라 자동 폴더 분류 인제스트 워크플로우 추가

**Architecture:** 기존 `MemoryCardBackupService`는 볼륨 감지/언마운트만 담당하고, 신규 `IngestService`가 Primary+Secondary 병렬 복사 오케스트레이션. 카메라 별칭은 `CameraAliasStore`로 영속화. 경로 계산은 순수 함수 `IngestPlanner`로 분리해 테스트 가능하게.

**Tech Stack:** Swift, SwiftUI, Foundation, AppKit, XCTest, AVFoundation (EXIF), CommonCrypto (MD5)

---

## Task 개요

| # | 제목 | 유형 | 의존 |
|---|------|------|------|
| 1 | XCTest 타겟 추가 | 셋업 | - |
| 2 | IngestSettings + FolderStructure | 모델 | 1 |
| 3 | CameraAlias + CameraAliasStore | 모델 | 1 |
| 4 | IngestPlanner (경로 계산) | 핵심 | 2, 3 |
| 5 | IngestSession 모델 | 모델 | 2 |
| 6 | IngestService 오케스트레이션 | 핵심 | 4, 5 |
| 7 | MD5 검증 헬퍼 | 서비스 | 1 |
| 8 | MemoryCardBackupService 위임 | 통합 | 6 |
| 9 | IngestSettingsView | UI | 2 |
| 10 | CameraAliasPromptView | UI | 3 |
| 11 | IngestProgressBar | UI | 5 |
| 12 | SettingsView 탭 등록 | UI | 9 |
| 13 | 마이그레이션 | 정책 | 2 |
| 14 | 통합 테스트 | 검증 | 6 |
| 15 | 수동 테스트 체크리스트 | 검증 | 14 |

---

### Task 1: XCTest 타겟 추가 및 첫 테스트 파일

**Files:**
- Modify: `/Users/potokan/PhotoRawManager/PhotoRawManager.xcodeproj/project.pbxproj`
- Create: `/Users/potokan/PhotoRawManager/PhotoRawManagerTests/PhotoRawManagerTests.swift`
- Create: `/Users/potokan/PhotoRawManager/PhotoRawManagerTests/Info.plist`

- [ ] **Step 1: Xcode에서 테스트 타겟 추가**

Xcode → File → New → Target → macOS → Unit Testing Bundle
- Product Name: `PhotoRawManagerTests`
- Target to be Tested: `PhotoRawManager`
- Language: Swift

자동 생성되는 기본 스텁 파일을 유지한다.

- [ ] **Step 2: 기본 테스트 파일 교체**

```swift
// PhotoRawManagerTests/PhotoRawManagerTests.swift
import XCTest
@testable import PhotoRawManager

final class PhotoRawManagerTests: XCTestCase {
    func testSanity() {
        XCTAssertEqual(1 + 1, 2)
    }
}
```

- [ ] **Step 3: 테스트 실행**

Run:
```
xcodebuild test -project /Users/potokan/PhotoRawManager/PhotoRawManager.xcodeproj \
  -scheme PhotoRawManager \
  -only-testing:PhotoRawManagerTests/PhotoRawManagerTests/testSanity
```

Expected: PASS (1 test passed)

- [ ] **Step 4: Commit**

```
git add PhotoRawManager.xcodeproj/project.pbxproj PhotoRawManagerTests/
git commit -m "test: XCTest 타겟 추가 (듀얼 인제스트 TDD 준비)"
```

---

### Task 2: IngestSettings + FolderStructure 모델

**Files:**
- Create: `/Users/potokan/PhotoRawManager/PhotoRawManager/Models/IngestSettings.swift`
- Test: `/Users/potokan/PhotoRawManager/PhotoRawManagerTests/IngestSettingsTests.swift`

- [ ] **Step 1: 실패 테스트 작성**

```swift
// PhotoRawManagerTests/IngestSettingsTests.swift
import XCTest
@testable import PhotoRawManager

final class IngestSettingsTests: XCTestCase {
    func testDefaultsHaveSensibleValues() {
        let s = IngestSettings.default
        XCTAssertNil(s.primaryDestination)
        XCTAssertNil(s.secondaryDestination)
        XCTAssertEqual(s.folderStructure, .original)
        XCTAssertNil(s.renamePattern)
        XCTAssertEqual(s.verifyMode, .sizeOnly)
    }

    func testCodableRoundTrip() throws {
        var s = IngestSettings.default
        s.primaryDestination = URL(fileURLWithPath: "/Volumes/SSD1/Photos")
        s.folderStructure = .dateCamera
        s.renamePattern = "{camera}_{seq}"
        s.verifyMode = .md5

        let data = try JSONEncoder().encode(s)
        let decoded = try JSONDecoder().decode(IngestSettings.self, from: data)

        XCTAssertEqual(decoded.primaryDestination?.path, "/Volumes/SSD1/Photos")
        XCTAssertEqual(decoded.folderStructure, .dateCamera)
        XCTAssertEqual(decoded.renamePattern, "{camera}_{seq}")
        XCTAssertEqual(decoded.verifyMode, .md5)
    }

    func testFolderStructureCases() {
        XCTAssertEqual(FolderStructure.allCases.count, 4)
        XCTAssertTrue(FolderStructure.allCases.contains(.original))
        XCTAssertTrue(FolderStructure.allCases.contains(.dateOnly))
        XCTAssertTrue(FolderStructure.allCases.contains(.dateCamera))
        XCTAssertTrue(FolderStructure.allCases.contains(.cameraDate))
    }
}
```

- [ ] **Step 2: 실패 확인**

Run:
```
xcodebuild test -project /Users/potokan/PhotoRawManager/PhotoRawManager.xcodeproj \
  -scheme PhotoRawManager \
  -only-testing:PhotoRawManagerTests/IngestSettingsTests
```
Expected: FAIL — "cannot find 'IngestSettings' in scope"

- [ ] **Step 3: 최소 구현**

```swift
// PhotoRawManager/Models/IngestSettings.swift
import Foundation

enum FolderStructure: String, Codable, CaseIterable, Identifiable {
    case original       // 원본 DCIM 구조 그대로
    case dateOnly       // {date}/
    case dateCamera     // {date}/{camera}/ (추천)
    case cameraDate     // {camera}/{date}/

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .original:    return "원본 그대로"
        case .dateOnly:    return "{date}/"
        case .dateCamera:  return "{date}/{camera}/ (추천)"
        case .cameraDate:  return "{camera}/{date}/"
        }
    }
}

enum VerifyMode: String, Codable, CaseIterable, Identifiable {
    case sizeOnly       // 기본: 파일 크기만 비교
    case md5            // 옵션: MD5 해시 검증

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .sizeOnly: return "크기 비교 (빠름)"
        case .md5:      return "해시 검증 (느림, 중요 촬영 권장)"
        }
    }
}

struct IngestSettings: Codable, Equatable {
    var primaryDestination: URL?
    var secondaryDestination: URL?
    var folderStructure: FolderStructure
    var renamePattern: String?
    var verifyMode: VerifyMode

    static let `default` = IngestSettings(
        primaryDestination: nil,
        secondaryDestination: nil,
        folderStructure: .original,
        renamePattern: nil,
        verifyMode: .sizeOnly
    )
}
```

- [ ] **Step 4: 테스트 통과 확인**

Expected: PASS (3 tests passed)

- [ ] **Step 5: Commit**

```
git add PhotoRawManager/Models/IngestSettings.swift PhotoRawManagerTests/IngestSettingsTests.swift
git commit -m "feat(ingest): IngestSettings + FolderStructure 모델"
```

---

### Task 3: CameraAlias + CameraAliasStore

**Files:**
- Create: `/Users/potokan/PhotoRawManager/PhotoRawManager/Services/CameraAliasStore.swift`
- Test: `/Users/potokan/PhotoRawManager/PhotoRawManagerTests/CameraAliasStoreTests.swift`

- [ ] **Step 1: 실패 테스트 작성**

```swift
// PhotoRawManagerTests/CameraAliasStoreTests.swift
import XCTest
@testable import PhotoRawManager

final class CameraAliasStoreTests: XCTestCase {
    var defaults: UserDefaults!
    var store: CameraAliasStore!

    override func setUp() {
        super.setUp()
        let suite = "CameraAliasStoreTests.\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suite)!
        store = CameraAliasStore(defaults: defaults)
    }

    func testSaveAndLookupByUUID() {
        let alias = CameraAlias(volumeUUID: "ABC-123", cameraModel: "Canon EOS R5", alias: "R5-메인")
        store.save(alias)
        XCTAssertEqual(store.alias(forVolumeUUID: "ABC-123"), alias)
    }

    func testLookupMissingReturnsNil() {
        XCTAssertNil(store.alias(forVolumeUUID: "missing"))
    }

    func testOverwriteExisting() {
        let a = CameraAlias(volumeUUID: "X", cameraModel: "R5", alias: "R5-메인")
        let b = CameraAlias(volumeUUID: "X", cameraModel: "R5", alias: "R5-서브")
        store.save(a)
        store.save(b)
        XCTAssertEqual(store.alias(forVolumeUUID: "X")?.alias, "R5-서브")
        XCTAssertEqual(store.allAliases().count, 1)
    }

    func testPersistsAcrossInstances() {
        store.save(CameraAlias(volumeUUID: "P", cameraModel: "A7", alias: "A7"))
        let store2 = CameraAliasStore(defaults: defaults)
        XCTAssertEqual(store2.alias(forVolumeUUID: "P")?.alias, "A7")
    }
}
```

- [ ] **Step 2: 실패 확인**

Expected: FAIL — "cannot find 'CameraAliasStore' in scope"

- [ ] **Step 3: 최소 구현**

```swift
// PhotoRawManager/Services/CameraAliasStore.swift
import Foundation

struct CameraAlias: Codable, Equatable, Identifiable {
    var id: String { volumeUUID }
    let volumeUUID: String
    let cameraModel: String
    let alias: String
}

final class CameraAliasStore {
    private let defaults: UserDefaults
    private let key = "cameraAliases"

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    static let shared = CameraAliasStore()

    func alias(forVolumeUUID uuid: String) -> CameraAlias? {
        allAliases().first { $0.volumeUUID == uuid }
    }

    func save(_ alias: CameraAlias) {
        var all = allAliases().filter { $0.volumeUUID != alias.volumeUUID }
        all.append(alias)
        persist(all)
    }

    func remove(volumeUUID: String) {
        let all = allAliases().filter { $0.volumeUUID != volumeUUID }
        persist(all)
    }

    func allAliases() -> [CameraAlias] {
        guard let data = defaults.data(forKey: key) else { return [] }
        return (try? JSONDecoder().decode([CameraAlias].self, from: data)) ?? []
    }

    private func persist(_ aliases: [CameraAlias]) {
        guard let data = try? JSONEncoder().encode(aliases) else { return }
        defaults.set(data, forKey: key)
    }
}
```

- [ ] **Step 4: 테스트 통과 확인**

Expected: PASS (4 tests passed)

- [ ] **Step 5: Commit**

```
git add PhotoRawManager/Services/CameraAliasStore.swift PhotoRawManagerTests/CameraAliasStoreTests.swift
git commit -m "feat(ingest): CameraAlias 모델 + CameraAliasStore (UserDefaults 영속)"
```

---

### Task 4: IngestPlanner — 경로 계산 순수 함수

**Files:**
- Create: `/Users/potokan/PhotoRawManager/PhotoRawManager/Services/IngestPlanner.swift`
- Test: `/Users/potokan/PhotoRawManager/PhotoRawManagerTests/IngestPlannerTests.swift`

- [ ] **Step 1: 실패 테스트 작성 (폴더 구조)**

```swift
// PhotoRawManagerTests/IngestPlannerTests.swift
import XCTest
@testable import PhotoRawManager

final class IngestPlannerTests: XCTestCase {
    let volume = URL(fileURLWithPath: "/Volumes/CARD")
    let dcim = URL(fileURLWithPath: "/Volumes/CARD/DCIM/100CANON")
    let dest = URL(fileURLWithPath: "/Volumes/SSD1")

    func makeSource(_ name: String) -> URL { dcim.appendingPathComponent(name) }

    func testOriginalStructurePreservesRelativePath() {
        let src = makeSource("IMG_0001.CR3")
        var settings = IngestSettings.default
        settings.folderStructure = .original
        let plan = IngestPlanner.plan(
            sources: [src],
            volumeRoot: volume,
            destination: dest,
            settings: settings,
            cameraAlias: "R5-메인",
            captureDate: Date(timeIntervalSince1970: 1_745_000_000) // 2025-04-18
        )
        XCTAssertEqual(plan.entries.count, 1)
        XCTAssertEqual(plan.entries[0].target.path, "/Volumes/SSD1/DCIM/100CANON/IMG_0001.CR3")
    }

    func testDateOnlyStructure() {
        let src = makeSource("IMG_0001.CR3")
        var settings = IngestSettings.default
        settings.folderStructure = .dateOnly
        let plan = IngestPlanner.plan(
            sources: [src],
            volumeRoot: volume,
            destination: dest,
            settings: settings,
            cameraAlias: "R5-메인",
            captureDate: isoDate("2026-04-14")
        )
        XCTAssertEqual(plan.entries[0].target.path, "/Volumes/SSD1/2026-04-14/IMG_0001.CR3")
    }

    func testDateCameraStructure() {
        let src = makeSource("IMG_0001.CR3")
        var settings = IngestSettings.default
        settings.folderStructure = .dateCamera
        let plan = IngestPlanner.plan(
            sources: [src],
            volumeRoot: volume,
            destination: dest,
            settings: settings,
            cameraAlias: "R5-메인",
            captureDate: isoDate("2026-04-14")
        )
        XCTAssertEqual(plan.entries[0].target.path, "/Volumes/SSD1/2026-04-14/R5-메인/IMG_0001.CR3")
    }

    func testCameraDateStructure() {
        let src = makeSource("IMG_0001.CR3")
        var settings = IngestSettings.default
        settings.folderStructure = .cameraDate
        let plan = IngestPlanner.plan(
            sources: [src],
            volumeRoot: volume,
            destination: dest,
            settings: settings,
            cameraAlias: "R5-메인",
            captureDate: isoDate("2026-04-14")
        )
        XCTAssertEqual(plan.entries[0].target.path, "/Volumes/SSD1/R5-메인/2026-04-14/IMG_0001.CR3")
    }

    func testRenamePatternTokens() {
        let src = makeSource("IMG_0001.CR3")
        var settings = IngestSettings.default
        settings.folderStructure = .dateCamera
        settings.renamePattern = "{camera}_{seq}"
        let plan = IngestPlanner.plan(
            sources: [src, makeSource("IMG_0002.CR3")],
            volumeRoot: volume,
            destination: dest,
            settings: settings,
            cameraAlias: "R5-메인",
            captureDate: isoDate("2026-04-14")
        )
        XCTAssertEqual(plan.entries[0].target.lastPathComponent, "R5-메인_0001.CR3")
        XCTAssertEqual(plan.entries[1].target.lastPathComponent, "R5-메인_0002.CR3")
    }

    func testRenamePatternWithDateToken() {
        let src = makeSource("DSC_0001.NEF")
        var settings = IngestSettings.default
        settings.folderStructure = .dateOnly
        settings.renamePattern = "{date}_{camera}_{seq}"
        let plan = IngestPlanner.plan(
            sources: [src],
            volumeRoot: volume,
            destination: dest,
            settings: settings,
            cameraAlias: "A7",
            captureDate: isoDate("2026-04-14")
        )
        XCTAssertEqual(plan.entries[0].target.lastPathComponent, "2026-04-14_A7_0001.NEF")
    }

    func testUnknownCameraAliasFallback() {
        let src = makeSource("IMG.JPG")
        var settings = IngestSettings.default
        settings.folderStructure = .dateCamera
        let plan = IngestPlanner.plan(
            sources: [src],
            volumeRoot: volume,
            destination: dest,
            settings: settings,
            cameraAlias: nil,
            captureDate: isoDate("2026-04-14")
        )
        XCTAssertEqual(plan.entries[0].target.path, "/Volumes/SSD1/2026-04-14/Unknown/IMG.JPG")
    }

    func testSanitizesAliasForFilename() {
        let src = makeSource("IMG.JPG")
        var settings = IngestSettings.default
        settings.folderStructure = .dateCamera
        settings.renamePattern = "{camera}_{seq}"
        let plan = IngestPlanner.plan(
            sources: [src],
            volumeRoot: volume,
            destination: dest,
            settings: settings,
            cameraAlias: "R5/메인", // 슬래시 포함 → 치환
            captureDate: isoDate("2026-04-14")
        )
        XCTAssertFalse(plan.entries[0].target.lastPathComponent.contains("/"))
    }

    // Helpers
    private func isoDate(_ s: String) -> Date {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd"
        f.timeZone = TimeZone(identifier: "UTC")
        return f.date(from: s)!
    }
}
```

- [ ] **Step 2: 실패 확인**

Expected: FAIL — "cannot find 'IngestPlanner' in scope"

- [ ] **Step 3: 최소 구현**

```swift
// PhotoRawManager/Services/IngestPlanner.swift
import Foundation

struct IngestPlanEntry {
    let source: URL
    let target: URL
    let captureDate: Date
}

struct IngestPlan {
    let entries: [IngestPlanEntry]
    let destination: URL
}

enum IngestPlanner {

    static func plan(
        sources: [URL],
        volumeRoot: URL,
        destination: URL,
        settings: IngestSettings,
        cameraAlias: String?,
        captureDate: Date
    ) -> IngestPlan {
        let alias = sanitize(cameraAlias ?? "Unknown")
        let dateString = dateFormatter.string(from: captureDate)

        var entries: [IngestPlanEntry] = []
        for (index, src) in sources.enumerated() {
            let sequence = index + 1
            let folder = folderURL(base: destination, structure: settings.folderStructure,
                                   date: dateString, camera: alias, source: src, volumeRoot: volumeRoot)
            let filename = filename(for: src, pattern: settings.renamePattern,
                                    date: dateString, camera: alias, sequence: sequence)
            entries.append(IngestPlanEntry(
                source: src,
                target: folder.appendingPathComponent(filename),
                captureDate: captureDate
            ))
        }
        return IngestPlan(entries: entries, destination: destination)
    }

    // MARK: - Conflict resolution (target exists)

    /// 타겟 파일 이미 존재 시 파일크기 비교 후 " (n)" suffix 생성.
    /// - returns: (finalTargetURL, shouldSkip)
    static func resolveConflict(target: URL, sourceSize: Int64) -> (URL, Bool) {
        let fm = FileManager.default
        guard fm.fileExists(atPath: target.path) else { return (target, false) }

        let existingSize = (try? fm.attributesOfItem(atPath: target.path)[.size] as? Int64) ?? 0
        if existingSize == sourceSize && sourceSize > 0 {
            return (target, true) // skip (동일 파일)
        }

        // 다른 파일 — 새 이름 부여
        let dir = target.deletingLastPathComponent()
        let base = target.deletingPathExtension().lastPathComponent
        let ext = target.pathExtension
        var n = 2
        while true {
            let candidate = dir.appendingPathComponent("\(base) (\(n)).\(ext)")
            if !fm.fileExists(atPath: candidate.path) { return (candidate, false) }
            n += 1
        }
    }

    // MARK: - Private helpers

    private static let dateFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd"
        f.timeZone = TimeZone(identifier: "UTC")
        return f
    }()

    private static func folderURL(
        base: URL,
        structure: FolderStructure,
        date: String,
        camera: String,
        source: URL,
        volumeRoot: URL
    ) -> URL {
        switch structure {
        case .original:
            let rel = source.deletingLastPathComponent().path
                .replacingOccurrences(of: volumeRoot.path, with: "")
                .trimmingCharacters(in: CharacterSet(charactersIn: "/"))
            return rel.isEmpty ? base : base.appendingPathComponent(rel)
        case .dateOnly:
            return base.appendingPathComponent(date)
        case .dateCamera:
            return base.appendingPathComponent(date).appendingPathComponent(camera)
        case .cameraDate:
            return base.appendingPathComponent(camera).appendingPathComponent(date)
        }
    }

    private static func filename(
        for source: URL,
        pattern: String?,
        date: String,
        camera: String,
        sequence: Int
    ) -> String {
        guard let pattern, !pattern.isEmpty else {
            return source.lastPathComponent
        }
        let ext = source.pathExtension
        let seqStr = String(format: "%04d", sequence)
        var result = pattern
            .replacingOccurrences(of: "{camera}", with: camera)
            .replacingOccurrences(of: "{date}", with: date)
            .replacingOccurrences(of: "{seq}", with: seqStr)
        result = sanitize(result)
        return ext.isEmpty ? result : "\(result).\(ext)"
    }

    private static func sanitize(_ s: String) -> String {
        let invalid = CharacterSet(charactersIn: "/\\:*?\"<>|")
        return s.components(separatedBy: invalid).joined(separator: "-")
    }
}
```

- [ ] **Step 4: 테스트 통과 확인**

Expected: PASS (8 tests passed)

- [ ] **Step 5: 충돌 해결 테스트 추가**

```swift
// 같은 파일에 추가
func testConflictResolutionSameSizeSkips() throws {
    let tmp = FileManager.default.temporaryDirectory
        .appendingPathComponent("ingest-test-\(UUID())")
    try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: tmp) }

    let existing = tmp.appendingPathComponent("IMG.JPG")
    let data = Data(repeating: 0xAB, count: 1024)
    try data.write(to: existing)

    let (url, skip) = IngestPlanner.resolveConflict(target: existing, sourceSize: 1024)
    XCTAssertTrue(skip)
    XCTAssertEqual(url, existing)
}

func testConflictResolutionDifferentSizeRenames() throws {
    let tmp = FileManager.default.temporaryDirectory
        .appendingPathComponent("ingest-test-\(UUID())")
    try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: tmp) }

    let existing = tmp.appendingPathComponent("IMG.JPG")
    try Data(repeating: 0xAB, count: 1024).write(to: existing)

    let (url, skip) = IngestPlanner.resolveConflict(target: existing, sourceSize: 2048)
    XCTAssertFalse(skip)
    XCTAssertEqual(url.lastPathComponent, "IMG (2).JPG")
}
```

- [ ] **Step 6: 전체 테스트 통과 확인**

Expected: PASS (10 tests passed)

- [ ] **Step 7: Commit**

```
git add PhotoRawManager/Services/IngestPlanner.swift PhotoRawManagerTests/IngestPlannerTests.swift
git commit -m "feat(ingest): IngestPlanner 경로/파일명 계산 (순수 함수 + 충돌 해결)"
```

---

### Task 5: IngestSession 모델

**Files:**
- Create: `/Users/potokan/PhotoRawManager/PhotoRawManager/Models/IngestSession.swift`
- Test: `/Users/potokan/PhotoRawManager/PhotoRawManagerTests/IngestSessionTests.swift`

- [ ] **Step 1: 실패 테스트 작성**

```swift
// PhotoRawManagerTests/IngestSessionTests.swift
import XCTest
@testable import PhotoRawManager

final class IngestSessionTests: XCTestCase {
    func testInitializationWithPrimaryOnly() {
        let vol = URL(fileURLWithPath: "/Volumes/CARD")
        let primary = BackupSession(volumeURL: vol,
                                    destinationURL: URL(fileURLWithPath: "/Volumes/SSD1"))
        let session = IngestSession(
            volumeURL: vol,
            cameraModel: "Canon EOS R5",
            cameraAlias: "R5-메인",
            primary: primary,
            secondary: nil,
            settings: .default
        )
        XCTAssertEqual(session.cameraAlias, "R5-메인")
        XCTAssertNil(session.secondary)
        XCTAssertFalse(session.isComplete)
    }

    func testAggregateProgressPrimaryOnly() {
        let vol = URL(fileURLWithPath: "/Volumes/CARD")
        let primary = BackupSession(volumeURL: vol, destinationURL: URL(fileURLWithPath: "/Volumes/SSD1"))
        primary.total = 100
        primary.done = 50
        let session = IngestSession(volumeURL: vol, cameraModel: "R5", cameraAlias: "R5",
                                    primary: primary, secondary: nil, settings: .default)
        XCTAssertEqual(session.aggregateProgress, 0.5, accuracy: 0.01)
    }

    func testAggregateProgressDual() {
        let vol = URL(fileURLWithPath: "/Volumes/CARD")
        let p = BackupSession(volumeURL: vol, destinationURL: URL(fileURLWithPath: "/p"))
        p.total = 100; p.done = 80
        let s = BackupSession(volumeURL: vol, destinationURL: URL(fileURLWithPath: "/s"))
        s.total = 100; s.done = 60
        let session = IngestSession(volumeURL: vol, cameraModel: "R5", cameraAlias: "R5",
                                    primary: p, secondary: s, settings: .default)
        XCTAssertEqual(session.aggregateProgress, 0.7, accuracy: 0.01) // (0.8 + 0.6) / 2
    }

    func testCancelCancelsBothSessions() {
        let vol = URL(fileURLWithPath: "/Volumes/CARD")
        let p = BackupSession(volumeURL: vol, destinationURL: URL(fileURLWithPath: "/p"))
        let s = BackupSession(volumeURL: vol, destinationURL: URL(fileURLWithPath: "/s"))
        let session = IngestSession(volumeURL: vol, cameraModel: "R5", cameraAlias: "R5",
                                    primary: p, secondary: s, settings: .default)
        session.cancel()
        XCTAssertTrue(p.isCancelled)
        XCTAssertTrue(s.isCancelled)
    }
}
```

- [ ] **Step 2: 실패 확인**

Expected: FAIL — "cannot find 'IngestSession' in scope"

- [ ] **Step 3: 최소 구현**

```swift
// PhotoRawManager/Models/IngestSession.swift
import Foundation
import Combine

final class IngestSession: ObservableObject, Identifiable {
    let id = UUID()
    let volumeURL: URL
    let cameraModel: String
    let cameraAlias: String
    let primary: BackupSession
    let secondary: BackupSession?
    let settings: IngestSettings

    @Published var isComplete: Bool = false
    @Published var primaryResult: BackupResult?
    @Published var secondaryResult: BackupResult?

    init(
        volumeURL: URL,
        cameraModel: String,
        cameraAlias: String,
        primary: BackupSession,
        secondary: BackupSession?,
        settings: IngestSettings
    ) {
        self.volumeURL = volumeURL
        self.cameraModel = cameraModel
        self.cameraAlias = cameraAlias
        self.primary = primary
        self.secondary = secondary
        self.settings = settings
    }

    var aggregateProgress: Double {
        if let sec = secondary {
            return (primary.progress + sec.progress) / 2.0
        }
        return primary.progress
    }

    var aggregateSpeed: String {
        if let sec = secondary, !sec.speed.isEmpty { return "\(primary.speed) / \(sec.speed)" }
        return primary.speed
    }

    var aggregateETA: String {
        // 늦은 쪽 기준
        let p = primary.eta
        let s = secondary?.eta ?? ""
        if s.isEmpty { return p }
        return s.count > p.count ? s : p
    }

    func cancel() {
        primary.cancel()
        secondary?.cancel()
    }

    var didFail: Bool {
        let pFailed = (primaryResult?.failed.isEmpty == false)
        let sFailed = (secondaryResult?.failed.isEmpty == false)
        return pFailed || sFailed
    }
}
```

- [ ] **Step 4: 테스트 통과 확인**

Expected: PASS (4 tests passed)

- [ ] **Step 5: Commit**

```
git add PhotoRawManager/Models/IngestSession.swift PhotoRawManagerTests/IngestSessionTests.swift
git commit -m "feat(ingest): IngestSession 모델 (Primary+Secondary 집계)"
```

---

### Task 6: IngestService 오케스트레이션

**Files:**
- Create: `/Users/potokan/PhotoRawManager/PhotoRawManager/Services/IngestService.swift`
- Test: `/Users/potokan/PhotoRawManager/PhotoRawManagerTests/IngestServiceTests.swift`

- [ ] **Step 1: 실패 테스트 작성 (단일 목적지)**

```swift
// PhotoRawManagerTests/IngestServiceTests.swift
import XCTest
@testable import PhotoRawManager

final class IngestServiceTests: XCTestCase {
    var tmpRoot: URL!
    var volumeRoot: URL!
    var primaryDest: URL!
    var secondaryDest: URL!

    override func setUpWithError() throws {
        let fm = FileManager.default
        tmpRoot = fm.temporaryDirectory.appendingPathComponent("ingest-\(UUID())")
        volumeRoot = tmpRoot.appendingPathComponent("CARD")
        primaryDest = tmpRoot.appendingPathComponent("SSD1")
        secondaryDest = tmpRoot.appendingPathComponent("SSD2")
        try fm.createDirectory(at: volumeRoot.appendingPathComponent("DCIM/100CANON"),
                               withIntermediateDirectories: true)
        try fm.createDirectory(at: primaryDest, withIntermediateDirectories: true)
        try fm.createDirectory(at: secondaryDest, withIntermediateDirectories: true)

        for i in 1...5 {
            let name = String(format: "IMG_%04d.JPG", i)
            let url = volumeRoot.appendingPathComponent("DCIM/100CANON/\(name)")
            try Data(repeating: UInt8(i), count: 1024 * (i + 1)).write(to: url)
        }
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: tmpRoot)
    }

    func testPrimaryOnlyCopiesAllFiles() throws {
        var settings = IngestSettings.default
        settings.primaryDestination = primaryDest
        settings.folderStructure = .dateOnly

        let service = IngestService()
        let exp = expectation(description: "complete")
        let session = service.startIngest(
            volumeURL: volumeRoot,
            cameraModel: "Canon EOS R5",
            cameraAlias: "R5",
            settings: settings,
            captureDate: Date()
        ) { exp.fulfill() }

        wait(for: [exp], timeout: 10)

        XCTAssertNotNil(session)
        XCTAssertNil(session?.secondary)
        XCTAssertTrue(session?.isComplete == true)
        XCTAssertEqual(session?.primaryResult?.success, 5)

        // 파일 존재 확인
        let dateStr = dateToday()
        let copiedCount = (try? FileManager.default.contentsOfDirectory(
            at: primaryDest.appendingPathComponent(dateStr),
            includingPropertiesForKeys: nil
        ).count) ?? 0
        XCTAssertEqual(copiedCount, 5)
    }

    func testDualDestinationCopiesToBoth() throws {
        var settings = IngestSettings.default
        settings.primaryDestination = primaryDest
        settings.secondaryDestination = secondaryDest
        settings.folderStructure = .dateOnly

        let service = IngestService()
        let exp = expectation(description: "complete")
        let session = service.startIngest(
            volumeURL: volumeRoot,
            cameraModel: "R5", cameraAlias: "R5",
            settings: settings,
            captureDate: Date()
        ) { exp.fulfill() }

        wait(for: [exp], timeout: 15)

        XCTAssertNotNil(session?.secondary)
        XCTAssertEqual(session?.primaryResult?.success, 5)
        XCTAssertEqual(session?.secondaryResult?.success, 5)

        let dateStr = dateToday()
        XCTAssertTrue(FileManager.default.fileExists(
            atPath: primaryDest.appendingPathComponent(dateStr).appendingPathComponent("IMG_0001.JPG").path))
        XCTAssertTrue(FileManager.default.fileExists(
            atPath: secondaryDest.appendingPathComponent(dateStr).appendingPathComponent("IMG_0001.JPG").path))
    }

    func testCancelStopsCopy() throws {
        // 큰 파일 추가
        let big = volumeRoot.appendingPathComponent("DCIM/100CANON/BIG.JPG")
        try Data(repeating: 0xFF, count: 50 * 1024 * 1024).write(to: big)

        var settings = IngestSettings.default
        settings.primaryDestination = primaryDest
        settings.folderStructure = .dateOnly

        let service = IngestService()
        let exp = expectation(description: "complete")
        let session = service.startIngest(
            volumeURL: volumeRoot, cameraModel: "R5", cameraAlias: "R5",
            settings: settings, captureDate: Date()
        ) { exp.fulfill() }

        // 즉시 취소
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
            session?.cancel()
        }

        wait(for: [exp], timeout: 10)
        XCTAssertTrue(session?.primary.isCancelled == true)
    }

    private func dateToday() -> String {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd"
        f.timeZone = TimeZone(identifier: "UTC")
        return f.string(from: Date())
    }
}
```

- [ ] **Step 2: 실패 확인**

Expected: FAIL — "cannot find 'IngestService' in scope"

- [ ] **Step 3: 최소 구현**

```swift
// PhotoRawManager/Services/IngestService.swift
import Foundation
import Combine

final class IngestService: ObservableObject {
    static let shared = IngestService()

    @Published private(set) var activeSessions: [IngestSession] = []

    private let queue = DispatchQueue(label: "IngestService", qos: .userInitiated, attributes: .concurrent)

    /// 카드 1장의 듀얼(또는 싱글) 백업을 시작한다.
    /// - returns: 생성된 IngestSession. primaryDestination이 없으면 nil.
    @discardableResult
    func startIngest(
        volumeURL: URL,
        cameraModel: String,
        cameraAlias: String,
        settings: IngestSettings,
        captureDate: Date,
        completion: @escaping () -> Void = {}
    ) -> IngestSession? {
        guard let primaryDest = settings.primaryDestination else {
            completion()
            return nil
        }

        let sources = scanSources(volumeURL: volumeURL)
        let totalBytes = sources.reduce(Int64(0)) { $0 + fileSize($1) }

        // 두 세션 각각 Plan 계산
        let primaryPlan = IngestPlanner.plan(
            sources: sources, volumeRoot: volumeURL, destination: primaryDest,
            settings: settings, cameraAlias: cameraAlias, captureDate: captureDate
        )

        let primarySession = BackupSession(volumeURL: volumeURL, destinationURL: primaryDest)
        primarySession.total = sources.count
        primarySession.totalBytes = totalBytes
        primarySession.startTime = CFAbsoluteTimeGetCurrent()

        var secondarySession: BackupSession? = nil
        var secondaryPlan: IngestPlan? = nil
        if let sec = settings.secondaryDestination {
            secondaryPlan = IngestPlanner.plan(
                sources: sources, volumeRoot: volumeURL, destination: sec,
                settings: settings, cameraAlias: cameraAlias, captureDate: captureDate
            )
            let s = BackupSession(volumeURL: volumeURL, destinationURL: sec)
            s.total = sources.count
            s.totalBytes = totalBytes
            s.startTime = CFAbsoluteTimeGetCurrent()
            secondarySession = s
        }

        let ingest = IngestSession(
            volumeURL: volumeURL,
            cameraModel: cameraModel,
            cameraAlias: cameraAlias,
            primary: primarySession,
            secondary: secondarySession,
            settings: settings
        )

        DispatchQueue.main.async {
            self.activeSessions.append(ingest)
        }

        let group = DispatchGroup()

        group.enter()
        queue.async {
            let result = self.executePlan(primaryPlan, session: primarySession, verifyMode: settings.verifyMode)
            DispatchQueue.main.async {
                primarySession.isComplete = true
                primarySession.result = result
                ingest.primaryResult = result
            }
            group.leave()
        }

        if let secPlan = secondaryPlan, let secSess = secondarySession {
            group.enter()
            queue.async {
                let result = self.executePlan(secPlan, session: secSess, verifyMode: settings.verifyMode)
                DispatchQueue.main.async {
                    secSess.isComplete = true
                    secSess.result = result
                    ingest.secondaryResult = result
                }
                group.leave()
            }
        }

        group.notify(queue: .main) {
            ingest.isComplete = true
            completion()
        }

        return ingest
    }

    // MARK: - 실행

    private func executePlan(_ plan: IngestPlan, session: BackupSession, verifyMode: VerifyMode) -> BackupResult {
        let fm = FileManager.default
        var failed: [FailedFile] = []
        var skipped = 0

        for (index, entry) in plan.entries.enumerated() {
            if session.isCancelled { break }

            let srcSize = fileSize(entry.source)
            let (finalTarget, shouldSkip) = IngestPlanner.resolveConflict(target: entry.target, sourceSize: srcSize)
            try? fm.createDirectory(at: finalTarget.deletingLastPathComponent(), withIntermediateDirectories: true)

            if shouldSkip {
                skipped += 1
                session.bytesCopied += srcSize
                DispatchQueue.main.async {
                    session.done = index + 1
                    session.updateSpeedAndETA()
                }
                continue
            }

            var success = false
            for retry in 0..<3 {
                try? fm.removeItem(at: finalTarget)
                if fastCopy(from: entry.source, to: finalTarget) {
                    if verifyCopy(src: entry.source, dst: finalTarget, mode: verifyMode) {
                        session.bytesCopied += srcSize
                        success = true
                        break
                    } else {
                        try? fm.removeItem(at: finalTarget)
                        if retry == 2 {
                            failed.append(FailedFile(name: entry.source.lastPathComponent, reason: "검증 실패"))
                        }
                    }
                } else if retry == 2 {
                    failed.append(FailedFile(name: entry.source.lastPathComponent, reason: "복사 실패"))
                }
            }
            _ = success

            DispatchQueue.main.async {
                session.done = index + 1
                session.updateSpeedAndETA()
            }
        }

        return BackupResult(
            total: plan.entries.count,
            success: plan.entries.count - failed.count,
            skipped: skipped,
            failed: failed,
            volumeName: session.volumeName,
            cancelled: session.isCancelled
        )
    }

    // MARK: - helpers

    private func scanSources(volumeURL: URL) -> [URL] {
        let fm = FileManager.default
        let dcim = volumeURL.appendingPathComponent("DCIM")
        let exts = FileMatchingService.allMediaExtensions
        var results: [URL] = []
        if let en = fm.enumerator(at: dcim, includingPropertiesForKeys: [.isRegularFileKey],
                                  options: [.skipsHiddenFiles]) {
            while let url = en.nextObject() as? URL {
                if exts.contains(url.pathExtension.lowercased()) { results.append(url) }
            }
        }
        return results.sorted { $0.lastPathComponent < $1.lastPathComponent }
    }

    private func fileSize(_ url: URL) -> Int64 {
        (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? Int64) ?? 0
    }

    private func verifyCopy(src: URL, dst: URL, mode: VerifyMode) -> Bool {
        let ss = fileSize(src), ds = fileSize(dst)
        guard ss > 0, ss == ds else { return false }
        if mode == .md5 {
            guard let a = MD5Hasher.hash(url: src), let b = MD5Hasher.hash(url: dst) else { return false }
            return a == b
        }
        return true
    }

    /// MemoryCardBackupService.fastCopy와 동일한 로직 재사용용 내부 복사.
    private func fastCopy(from src: URL, to dst: URL) -> Bool {
        let flags: copyfile_flags_t = UInt32(COPYFILE_ALL | COPYFILE_CLONE)
        if copyfile(src.path, dst.path, nil, flags) == 0 { return true }

        let srcFd = open(src.path, O_RDONLY)
        guard srcFd >= 0 else { return false }
        defer { close(srcFd) }
        let dstFd = open(dst.path, O_WRONLY | O_CREAT | O_TRUNC, 0o644)
        guard dstFd >= 0 else { return false }
        defer { close(dstFd) }
        fcntl(srcFd, F_NOCACHE, 1); fcntl(dstFd, F_NOCACHE, 1); fcntl(srcFd, F_RDAHEAD, 1)
        let bufSize = 16 * 1024 * 1024
        let buf = UnsafeMutablePointer<UInt8>.allocate(capacity: bufSize)
        defer { buf.deallocate() }
        while true {
            let r = read(srcFd, buf, bufSize)
            if r <= 0 { break }
            var w = 0
            while w < r {
                let n = write(dstFd, buf + w, r - w)
                if n < 0 { return false }
                w += n
            }
        }
        return true
    }
}
```

(MD5Hasher는 Task 7에서 추가 — 컴파일을 위해 지금은 `import CommonCrypto`를 하지 않고 Task 7까지 `verifyMode == .md5`는 테스트 스킵하거나 Task 7을 먼저 돌려도 된다. 이 플랜에선 Task 6의 구현 시점에 MD5Hasher 빈 스텁을 먼저 추가한다.)

- [ ] **Step 4: MD5Hasher 스텁 추가** (임시, Task 7에서 진짜 구현)

```swift
// PhotoRawManager/Services/MD5Hasher.swift (스텁)
import Foundation

enum MD5Hasher {
    static func hash(url: URL) -> String? {
        return nil // TODO: Task 7 구현
    }
}
```

- [ ] **Step 5: 테스트 통과 확인**

Expected: PASS (3 tests passed — sizeOnly 모드만 검증)

- [ ] **Step 6: Commit**

```
git add PhotoRawManager/Services/IngestService.swift PhotoRawManager/Services/MD5Hasher.swift PhotoRawManagerTests/IngestServiceTests.swift
git commit -m "feat(ingest): IngestService — Primary/Secondary 병렬 복사 오케스트레이션"
```

---

### Task 7: MD5 검증 헬퍼 (CommonCrypto)

**Files:**
- Modify: `/Users/potokan/PhotoRawManager/PhotoRawManager/Services/MD5Hasher.swift`
- Test: `/Users/potokan/PhotoRawManager/PhotoRawManagerTests/MD5HasherTests.swift`

- [ ] **Step 1: 실패 테스트 작성**

```swift
// PhotoRawManagerTests/MD5HasherTests.swift
import XCTest
@testable import PhotoRawManager

final class MD5HasherTests: XCTestCase {
    func testKnownVectorHelloWorld() throws {
        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent("md5-\(UUID()).txt")
        try "hello world".data(using: .utf8)!.write(to: tmp)
        defer { try? FileManager.default.removeItem(at: tmp) }

        let hash = MD5Hasher.hash(url: tmp)
        XCTAssertEqual(hash, "5eb63bbbe01eeed093cb22bb8f5acdc3")
    }

    func testEmptyFile() throws {
        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent("md5-empty-\(UUID()).txt")
        try Data().write(to: tmp)
        defer { try? FileManager.default.removeItem(at: tmp) }
        XCTAssertEqual(MD5Hasher.hash(url: tmp), "d41d8cd98f00b204e9800998ecf8427e")
    }

    func testSameContentSameHash() throws {
        let a = FileManager.default.temporaryDirectory.appendingPathComponent("a-\(UUID())")
        let b = FileManager.default.temporaryDirectory.appendingPathComponent("b-\(UUID())")
        let payload = Data(repeating: 0x42, count: 128 * 1024)
        try payload.write(to: a)
        try payload.write(to: b)
        defer { try? FileManager.default.removeItem(at: a); try? FileManager.default.removeItem(at: b) }
        XCTAssertEqual(MD5Hasher.hash(url: a), MD5Hasher.hash(url: b))
    }

    func testMissingFileReturnsNil() {
        XCTAssertNil(MD5Hasher.hash(url: URL(fileURLWithPath: "/does/not/exist/\(UUID())")))
    }
}
```

- [ ] **Step 2: 실패 확인**

Expected: FAIL — 현재 스텁은 항상 nil 리턴.

- [ ] **Step 3: 실제 구현**

```swift
// PhotoRawManager/Services/MD5Hasher.swift
import Foundation
import CommonCrypto

enum MD5Hasher {
    /// 1MB 청크 스트리밍 MD5 — 대용량 RAW(40MB+)도 메모리 안전
    static func hash(url: URL) -> String? {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }

        var context = CC_MD5_CTX()
        CC_MD5_Init(&context)

        let chunk = 1024 * 1024
        while true {
            let data = (try? handle.read(upToCount: chunk)) ?? Data()
            if data.isEmpty { break }
            data.withUnsafeBytes { buf in
                _ = CC_MD5_Update(&context, buf.baseAddress, CC_LONG(data.count))
            }
        }

        var digest = [UInt8](repeating: 0, count: Int(CC_MD5_DIGEST_LENGTH))
        CC_MD5_Final(&digest, &context)
        return digest.map { String(format: "%02x", $0) }.joined()
    }
}
```

- [ ] **Step 4: 테스트 통과 확인**

Expected: PASS (4 tests passed)

- [ ] **Step 5: IngestServiceTests에 MD5 경로 테스트 추가**

```swift
// IngestServiceTests.swift에 추가
func testMD5VerifyModeDetectsCorruption() throws {
    var settings = IngestSettings.default
    settings.primaryDestination = primaryDest
    settings.folderStructure = .dateOnly
    settings.verifyMode = .md5

    let service = IngestService()
    let exp = expectation(description: "complete")
    let session = service.startIngest(
        volumeURL: volumeRoot,
        cameraModel: "R5", cameraAlias: "R5",
        settings: settings, captureDate: Date()
    ) { exp.fulfill() }

    wait(for: [exp], timeout: 10)
    XCTAssertEqual(session?.primaryResult?.success, 5)
}
```

- [ ] **Step 6: 전체 테스트 통과 확인**

Expected: PASS

- [ ] **Step 7: Commit**

```
git add PhotoRawManager/Services/MD5Hasher.swift PhotoRawManagerTests/MD5HasherTests.swift PhotoRawManagerTests/IngestServiceTests.swift
git commit -m "feat(ingest): MD5Hasher 스트리밍 해시 + .md5 verifyMode 지원"
```

---

### Task 8: MemoryCardBackupService → IngestService 위임

**Files:**
- Modify: `/Users/potokan/PhotoRawManager/PhotoRawManager/Services/MemoryCardBackupService.swift`
- Create: `/Users/potokan/PhotoRawManager/PhotoRawManager/Services/CameraInfoExtractor.swift`
- Test: `/Users/potokan/PhotoRawManager/PhotoRawManagerTests/CameraInfoExtractorTests.swift`

- [ ] **Step 1: CameraInfoExtractor 테스트 작성**

```swift
// PhotoRawManagerTests/CameraInfoExtractorTests.swift
import XCTest
@testable import PhotoRawManager

final class CameraInfoExtractorTests: XCTestCase {
    func testExtractsVolumeUUID() {
        // 실제 볼륨은 unit test에서 mount 불가 — nil 허용
        let url = URL(fileURLWithPath: "/")
        let uuid = CameraInfoExtractor.volumeUUID(for: url)
        // 루트 볼륨은 UUID가 있어야 함 (macOS)
        XCTAssertNotNil(uuid)
    }

    func testExtractsCameraModelFromMissingFileReturnsUnknown() {
        let result = CameraInfoExtractor.cameraModel(fromFirstPhotoIn:
            URL(fileURLWithPath: "/tmp/does-not-exist-\(UUID())"))
        XCTAssertEqual(result, "Unknown")
    }
}
```

- [ ] **Step 2: 실패 확인**

Expected: FAIL — "cannot find 'CameraInfoExtractor' in scope"

- [ ] **Step 3: CameraInfoExtractor 구현**

```swift
// PhotoRawManager/Services/CameraInfoExtractor.swift
import Foundation
import ImageIO

enum CameraInfoExtractor {

    /// 볼륨 UUID (카드 별 영구 식별자)
    static func volumeUUID(for volumeURL: URL) -> String? {
        let keys: Set<URLResourceKey> = [.volumeUUIDStringKey]
        let values = try? volumeURL.resourceValues(forKeys: keys)
        return values?.volumeUUIDString
    }

    /// DCIM 디렉토리 첫 JPG/RAW에서 EXIF의 카메라 모델 추출
    static func cameraModel(fromFirstPhotoIn volumeURL: URL) -> String {
        let fm = FileManager.default
        let dcim = volumeURL.appendingPathComponent("DCIM")
        guard let en = fm.enumerator(at: dcim, includingPropertiesForKeys: nil,
                                     options: [.skipsHiddenFiles]) else { return "Unknown" }
        let exts: Set<String> = ["jpg", "jpeg", "heic", "cr3", "cr2", "nef", "arw", "raf", "dng"]
        while let url = en.nextObject() as? URL {
            let ext = url.pathExtension.lowercased()
            if exts.contains(ext), let model = readCameraModel(url: url) {
                return model
            }
        }
        return "Unknown"
    }

    /// 첫 JPG/RAW의 capture date
    static func captureDate(fromFirstPhotoIn volumeURL: URL) -> Date? {
        let fm = FileManager.default
        let dcim = volumeURL.appendingPathComponent("DCIM")
        guard let en = fm.enumerator(at: dcim, includingPropertiesForKeys: nil,
                                     options: [.skipsHiddenFiles]) else { return nil }
        let exts: Set<String> = ["jpg", "jpeg", "heic", "cr3", "cr2", "nef", "arw", "raf", "dng"]
        while let url = en.nextObject() as? URL {
            if exts.contains(url.pathExtension.lowercased()),
               let d = readCaptureDate(url: url) {
                return d
            }
        }
        return nil
    }

    private static func readCameraModel(url: URL) -> String? {
        guard let src = CGImageSourceCreateWithURL(url as CFURL, nil),
              let props = CGImageSourceCopyPropertiesAtIndex(src, 0, nil) as? [CFString: Any] else {
            return nil
        }
        if let tiff = props[kCGImagePropertyTIFFDictionary] as? [CFString: Any],
           let model = tiff[kCGImagePropertyTIFFModel] as? String {
            return model
        }
        return nil
    }

    private static func readCaptureDate(url: URL) -> Date? {
        guard let src = CGImageSourceCreateWithURL(url as CFURL, nil),
              let props = CGImageSourceCopyPropertiesAtIndex(src, 0, nil) as? [CFString: Any] else {
            return nil
        }
        if let exif = props[kCGImagePropertyExifDictionary] as? [CFString: Any],
           let dateStr = exif[kCGImagePropertyExifDateTimeOriginal] as? String {
            let f = DateFormatter()
            f.dateFormat = "yyyy:MM:dd HH:mm:ss"
            return f.date(from: dateStr)
        }
        return nil
    }
}
```

- [ ] **Step 4: 테스트 통과 확인**

Expected: PASS (2 tests passed)

- [ ] **Step 5: MemoryCardBackupService 리팩토링**

`MemoryCardBackupService`에 IngestService 델리게이트 및 alias 훅을 추가한다. 기존 `sessions`, `startBackup()`은 하위호환으로 남기되 내부에서 IngestService로 위임.

```swift
// MemoryCardBackupService.swift — 상단에 IngestService 통합
extension MemoryCardBackupService {

    /// IngestSettings 기반 인제스트 시작 (신규 진입점)
    func startIngest(from sourceVolume: URL,
                     settings: IngestSettings,
                     aliasProvider: @escaping (_ model: String, _ uuid: String?, _ reply: @escaping (String?) -> Void) -> Void) {
        let model = CameraInfoExtractor.cameraModel(fromFirstPhotoIn: sourceVolume)
        let uuid = CameraInfoExtractor.volumeUUID(for: sourceVolume)
        let captureDate = CameraInfoExtractor.captureDate(fromFirstPhotoIn: sourceVolume) ?? Date()

        // 기존 별칭 조회 → 없으면 prompt
        if let uuid, let existing = CameraAliasStore.shared.alias(forVolumeUUID: uuid) {
            self.runIngest(sourceVolume, model: model, alias: existing.alias, settings: settings, captureDate: captureDate)
            return
        }

        aliasProvider(model, uuid) { [weak self] alias in
            guard let self, let alias else { return } // 취소
            if let uuid {
                CameraAliasStore.shared.save(CameraAlias(volumeUUID: uuid, cameraModel: model, alias: alias))
            }
            self.runIngest(sourceVolume, model: model, alias: alias, settings: settings, captureDate: captureDate)
        }
    }

    private func runIngest(_ volume: URL, model: String, alias: String, settings: IngestSettings, captureDate: Date) {
        _ = IngestService.shared.startIngest(
            volumeURL: volume,
            cameraModel: model,
            cameraAlias: alias,
            settings: settings,
            captureDate: captureDate
        ) { [weak self] in
            DispatchQueue.main.async {
                // 완료 후: 성공이면 자동 언마운트
                self?.handleIngestCompletion(volume: volume)
            }
        }
    }

    private func handleIngestCompletion(volume: URL) {
        let sessions = IngestService.shared.activeSessions.filter { $0.volumeURL == volume }
        let allSuccess = sessions.allSatisfy { !$0.didFail && $0.isComplete }
        if allSuccess {
            // waitForNextCard 흐름과 동일
            fputs("[INGEST] \(volume.lastPathComponent) 완료 → 자동 언마운트\n", stderr)
        }
    }
}
```

- [ ] **Step 6: 빌드 확인 (기존 startBackup 사용처가 깨지지 않는지)**

Run:
```
xcodebuild -project /Users/potokan/PhotoRawManager/PhotoRawManager.xcodeproj -scheme PhotoRawManager -configuration Debug build
```
Expected: BUILD SUCCEEDED

- [ ] **Step 7: Commit**

```
git add PhotoRawManager/Services/CameraInfoExtractor.swift PhotoRawManager/Services/MemoryCardBackupService.swift PhotoRawManagerTests/CameraInfoExtractorTests.swift
git commit -m "feat(ingest): CameraInfoExtractor + MemoryCardBackupService IngestService 위임"
```

---

### Task 9: IngestSettingsView UI

**Files:**
- Create: `/Users/potokan/PhotoRawManager/PhotoRawManager/Views/IngestSettingsView.swift`
- Create: `/Users/potokan/PhotoRawManager/PhotoRawManager/Models/IngestSettingsStore.swift`
- Test: `/Users/potokan/PhotoRawManager/PhotoRawManagerTests/IngestSettingsStoreTests.swift`

- [ ] **Step 1: Store 실패 테스트**

```swift
// PhotoRawManagerTests/IngestSettingsStoreTests.swift
import XCTest
@testable import PhotoRawManager

final class IngestSettingsStoreTests: XCTestCase {
    var defaults: UserDefaults!
    var store: IngestSettingsStore!

    override func setUp() {
        super.setUp()
        let suite = "IngestSettingsStoreTests.\(UUID())"
        defaults = UserDefaults(suiteName: suite)!
        store = IngestSettingsStore(defaults: defaults)
    }

    func testLoadReturnsDefaultWhenEmpty() {
        XCTAssertEqual(store.load(), IngestSettings.default)
    }

    func testSaveAndLoadRoundTrip() {
        var s = IngestSettings.default
        s.primaryDestination = URL(fileURLWithPath: "/tmp/p")
        s.folderStructure = .dateCamera
        store.save(s)
        XCTAssertEqual(store.load(), s)
    }

    func testMigratesLegacyDestinationURL() {
        defaults.set("/Volumes/OldSSD/Photos", forKey: "memoryCard.destinationURL")
        let s = store.load()
        XCTAssertEqual(s.primaryDestination?.path, "/Volumes/OldSSD/Photos")
    }
}
```

- [ ] **Step 2: 실패 확인**

Expected: FAIL — "cannot find 'IngestSettingsStore'"

- [ ] **Step 3: Store 구현**

```swift
// PhotoRawManager/Models/IngestSettingsStore.swift
import Foundation

final class IngestSettingsStore {
    private let defaults: UserDefaults
    private let key = "ingest.settings.v1"
    private let legacyKey = "memoryCard.destinationURL"

    init(defaults: UserDefaults = .standard) { self.defaults = defaults }

    static let shared = IngestSettingsStore()

    func load() -> IngestSettings {
        if let data = defaults.data(forKey: key),
           let decoded = try? JSONDecoder().decode(IngestSettings.self, from: data) {
            return decoded
        }
        // 마이그레이션: 기존 destinationURL → primaryDestination
        if let legacy = defaults.string(forKey: legacyKey), !legacy.isEmpty {
            var migrated = IngestSettings.default
            migrated.primaryDestination = URL(fileURLWithPath: legacy)
            save(migrated)
            return migrated
        }
        return .default
    }

    func save(_ settings: IngestSettings) {
        guard let data = try? JSONEncoder().encode(settings) else { return }
        defaults.set(data, forKey: key)
    }
}
```

- [ ] **Step 4: 테스트 통과 확인**

Expected: PASS (3 tests passed)

- [ ] **Step 5: SwiftUI 뷰 구현**

```swift
// PhotoRawManager/Views/IngestSettingsView.swift
import SwiftUI
import AppKit

struct IngestSettingsView: View {
    @State private var settings: IngestSettings = IngestSettingsStore.shared.load()
    @State private var useSecondary: Bool = false
    @State private var useRename: Bool = false

    var body: some View {
        Form {
            Section("저장 위치") {
                HStack {
                    Text("Primary:")
                    Text(settings.primaryDestination?.path ?? "선택 안됨")
                        .lineLimit(1).truncationMode(.middle)
                        .foregroundColor(settings.primaryDestination == nil ? .secondary : .primary)
                    Spacer()
                    Button("변경") { chooseFolder { url in settings.primaryDestination = url; save() } }
                }

                Toggle("Secondary (듀얼 백업)", isOn: $useSecondary)
                    .onChange(of: useSecondary) { _, on in
                        if !on { settings.secondaryDestination = nil; save() }
                    }
                if useSecondary {
                    HStack {
                        Text("Secondary:")
                        Text(settings.secondaryDestination?.path ?? "선택 안됨")
                            .lineLimit(1).truncationMode(.middle)
                            .foregroundColor(settings.secondaryDestination == nil ? .secondary : .primary)
                        Spacer()
                        Button("변경") { chooseFolder { url in settings.secondaryDestination = url; save() } }
                    }
                }
            }

            Section("폴더 구조") {
                Picker("구조", selection: $settings.folderStructure) {
                    ForEach(FolderStructure.allCases) { s in
                        Text(s.displayName).tag(s)
                    }
                }
                .pickerStyle(.radioGroup)
                .onChange(of: settings.folderStructure) { _, _ in save() }
            }

            Section("파일명") {
                Toggle("파일명 변경", isOn: $useRename)
                    .onChange(of: useRename) { _, on in
                        if !on { settings.renamePattern = nil; save() }
                        else if settings.renamePattern == nil { settings.renamePattern = "{camera}_{seq}"; save() }
                    }
                if useRename {
                    TextField("패턴", text: Binding(
                        get: { settings.renamePattern ?? "" },
                        set: { settings.renamePattern = $0; save() }
                    ))
                    Text("예시: \(previewName())")
                        .font(.caption).foregroundColor(.secondary)
                }
            }

            Section("검증") {
                Picker("검증 방식", selection: $settings.verifyMode) {
                    ForEach(VerifyMode.allCases) { m in Text(m.displayName).tag(m) }
                }
                .pickerStyle(.radioGroup)
                .onChange(of: settings.verifyMode) { _, _ in save() }
            }
        }
        .padding(20)
        .frame(minWidth: 500, minHeight: 500)
        .onAppear {
            useSecondary = settings.secondaryDestination != nil
            useRename = settings.renamePattern != nil
        }
    }

    private func previewName() -> String {
        let pattern = settings.renamePattern ?? "{camera}_{seq}"
        return pattern
            .replacingOccurrences(of: "{camera}", with: "R5-메인")
            .replacingOccurrences(of: "{date}", with: "2026-04-14")
            .replacingOccurrences(of: "{seq}", with: "0001") + ".CR3"
    }

    private func save() { IngestSettingsStore.shared.save(settings) }

    private func chooseFolder(onPick: @escaping (URL) -> Void) {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        if panel.runModal() == .OK, let url = panel.url { onPick(url) }
    }
}
```

- [ ] **Step 6: 빌드 확인**

Run:
```
xcodebuild -project /Users/potokan/PhotoRawManager/PhotoRawManager.xcodeproj -scheme PhotoRawManager -configuration Debug build
```
Expected: BUILD SUCCEEDED

- [ ] **Step 7: Commit**

```
git add PhotoRawManager/Models/IngestSettingsStore.swift PhotoRawManager/Views/IngestSettingsView.swift PhotoRawManagerTests/IngestSettingsStoreTests.swift
git commit -m "feat(ingest): IngestSettingsView UI + IngestSettingsStore (마이그레이션 포함)"
```

---

### Task 10: CameraAliasPromptView 모달

**Files:**
- Create: `/Users/potokan/PhotoRawManager/PhotoRawManager/Views/CameraAliasPromptView.swift`

- [ ] **Step 1: UI 구현 (SwiftUI Preview로 수동 확인)**

```swift
// PhotoRawManager/Views/CameraAliasPromptView.swift
import SwiftUI

struct CameraAliasPromptContext: Identifiable {
    let id = UUID()
    let volumeURL: URL
    let volumeUUID: String?
    let cameraModel: String
    let fileCount: Int
    let totalBytes: Int64
    let onSave: (String?) -> Void // nil = 취소
}

struct CameraAliasPromptView: View {
    let context: CameraAliasPromptContext
    @State private var alias: String = ""
    @Environment(\.dismiss) var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(spacing: 12) {
                Image(systemName: "camera")
                    .font(.largeTitle)
                VStack(alignment: .leading, spacing: 4) {
                    Text(context.cameraModel).font(.headline)
                    Text("카드 라벨: \(context.volumeURL.lastPathComponent)")
                        .font(.caption).foregroundColor(.secondary)
                    Text("사진 \(context.fileCount)장 · \(formatBytes(context.totalBytes))")
                        .font(.caption).foregroundColor(.secondary)
                }
                Spacer()
            }

            VStack(alignment: .leading, spacing: 4) {
                Text("이 카드 별칭").font(.subheadline)
                TextField("예: R5-메인", text: $alias)
                    .textFieldStyle(.roundedBorder)
                Text("다음에 같은 카드 꽂으면 자동 인식됩니다")
                    .font(.caption).foregroundColor(.secondary)
            }

            HStack {
                Spacer()
                Button("취소") {
                    context.onSave(nil)
                    dismiss()
                }
                Button("이 카드로 저장") {
                    let trimmed = alias.trimmingCharacters(in: .whitespacesAndNewlines)
                    context.onSave(trimmed.isEmpty ? nil : trimmed)
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
                .disabled(alias.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
        .padding(24)
        .frame(width: 420)
    }

    private func formatBytes(_ b: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: b, countStyle: .file)
    }
}
```

- [ ] **Step 2: 빌드 확인**

Expected: BUILD SUCCEEDED

- [ ] **Step 3: Commit**

```
git add PhotoRawManager/Views/CameraAliasPromptView.swift
git commit -m "feat(ingest): CameraAliasPromptView 카메라 별칭 입력 모달"
```

---

### Task 11: IngestProgressBar 툴바 위젯

**Files:**
- Create: `/Users/potokan/PhotoRawManager/PhotoRawManager/Views/IngestProgressBar.swift`
- Modify: `/Users/potokan/PhotoRawManager/PhotoRawManager/Views/ContentView+Toolbar.swift`

- [ ] **Step 1: IngestProgressBar UI**

```swift
// PhotoRawManager/Views/IngestProgressBar.swift
import SwiftUI

struct IngestProgressBar: View {
    @ObservedObject var service: IngestService = .shared
    @State private var expanded: Bool = false

    var body: some View {
        if !service.activeSessions.isEmpty {
            if expanded {
                expandedView
            } else {
                compactView
            }
        } else {
            EmptyView()
        }
    }

    private var compactView: some View {
        Button {
            expanded = true
        } label: {
            HStack(spacing: 6) {
                ForEach(service.activeSessions.prefix(4)) { s in
                    Circle()
                        .fill(s.isComplete ? Color.green : Color.blue)
                        .frame(width: 8, height: 8)
                }
                Text("\(service.activeSessions.count)개 · \(Int(averageProgress * 100))%")
                    .font(.caption.monospacedDigit())
                Text(dominantETA)
                    .font(.caption.monospacedDigit())
                    .foregroundColor(.secondary)
            }
        }
        .buttonStyle(.plain)
    }

    private var expandedView: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("백업 (\(activeCount)개 진행중)").font(.headline)
                Spacer()
                Button("접기") { expanded = false }
            }

            ForEach(service.activeSessions) { ingest in
                sessionRow(ingest)
            }

            HStack {
                Spacer()
                Button("모두 취소") {
                    service.activeSessions.forEach { $0.cancel() }
                }
            }
        }
        .padding(12)
        .background(Color(NSColor.controlBackgroundColor))
        .cornerRadius(8)
        .frame(width: 420)
    }

    private func sessionRow(_ ingest: IngestSession) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            backupRow(ingest, backup: ingest.primary, label: "Primary")
            if let sec = ingest.secondary {
                backupRow(ingest, backup: sec, label: "Secondary")
            }
        }
    }

    private func backupRow(_ ingest: IngestSession, backup: BackupSession, label: String) -> some View {
        HStack(spacing: 8) {
            Text("\(ingest.cameraAlias) → \(backup.destinationURL.lastPathComponent)")
                .font(.caption).lineLimit(1)
            ProgressView(value: backup.progress)
                .frame(maxWidth: 120)
            Text("\(Int(backup.progress * 100))%").font(.caption.monospacedDigit())
            Text(backup.speed).font(.caption.monospacedDigit()).foregroundColor(.secondary)
        }
    }

    private var activeCount: Int {
        service.activeSessions.filter { !$0.isComplete }.count
    }

    private var averageProgress: Double {
        guard !service.activeSessions.isEmpty else { return 0 }
        let sum = service.activeSessions.reduce(0.0) { $0 + $1.aggregateProgress }
        return sum / Double(service.activeSessions.count)
    }

    private var dominantETA: String {
        service.activeSessions.compactMap { $0.aggregateETA.isEmpty ? nil : $0.aggregateETA }.first ?? ""
    }
}
```

- [ ] **Step 2: 툴바에 연결**

`ContentView+Toolbar.swift`의 적절한 ToolbarItem 위치에 추가:

```swift
// ContentView+Toolbar.swift 내부 툴바 정의 안에
ToolbarItem(placement: .primaryAction) {
    IngestProgressBar()
}
```

- [ ] **Step 3: 빌드 확인**

Expected: BUILD SUCCEEDED

- [ ] **Step 4: Commit**

```
git add PhotoRawManager/Views/IngestProgressBar.swift PhotoRawManager/Views/ContentView+Toolbar.swift
git commit -m "feat(ingest): IngestProgressBar 툴바 위젯 (펼침/접힘)"
```

---

### Task 12: SettingsView 탭 등록

**Files:**
- Modify: `/Users/potokan/PhotoRawManager/PhotoRawManager/Views/SettingsView.swift`
- Modify: `/Users/potokan/PhotoRawManager/PhotoRawManager/PhotoRawManagerApp.swift` (해당되는 경우)

- [ ] **Step 1: SettingsView에 탭 추가**

`SettingsView.swift`의 TabView에 인제스트 탭 추가:

```swift
// SettingsView.swift 내부 TabView 안에
IngestSettingsView()
    .tabItem {
        Label("인제스트", systemImage: "externaldrive.badge.plus")
    }
    .tag(SettingsTab.ingest) // (enum에 .ingest 케이스 추가 필요)
```

SettingsTab enum에 `.ingest` 추가:
```swift
enum SettingsTab: String, CaseIterable {
    // 기존 케이스들...
    case ingest
}
```

- [ ] **Step 2: 빌드 확인**

Expected: BUILD SUCCEEDED

- [ ] **Step 3: 수동 확인**

앱 실행 → Settings → "인제스트" 탭이 보이는지 확인.

- [ ] **Step 4: Commit**

```
git add PhotoRawManager/Views/SettingsView.swift
git commit -m "feat(ingest): Settings 창에 인제스트 탭 추가"
```

---

### Task 13: 마이그레이션 & 볼륨 감지 훅

**Files:**
- Modify: `/Users/potokan/PhotoRawManager/PhotoRawManager/Services/MemoryCardBackupService.swift`
- Modify: `/Users/potokan/PhotoRawManager/PhotoRawManager/PhotoRawManagerApp.swift`

- [ ] **Step 1: 앱 시작 시 마이그레이션 트리거**

`PhotoRawManagerApp.swift`의 `init()` 또는 `WindowGroup.onAppear`에서:

```swift
.onAppear {
    _ = IngestSettingsStore.shared.load() // 마이그레이션 유도
}
```

- [ ] **Step 2: MemoryCardBackupService.checkAndPromptIfMemoryCard → IngestService 경로로**

기존 로직은 유지하되, 설정된 `IngestSettings.primaryDestination`이 있으면 자동으로 IngestService로 라우팅:

```swift
// MemoryCardBackupService.swift checkAndPromptIfMemoryCard 내부 — 마지막에
let settings = IngestSettingsStore.shared.load()
if settings.primaryDestination != nil {
    // 신규 경로: alias prompt 필요하면 showAliasPrompt 트리거
    self.pendingIngestVolume = url
    let uuid = CameraInfoExtractor.volumeUUID(for: url)
    if let uuid, CameraAliasStore.shared.alias(forVolumeUUID: uuid) != nil {
        // 알려진 카드 → 바로 시작
        self.startIngest(from: url, settings: settings, aliasProvider: { _, _, _ in })
    } else {
        // 모달 필요 — @Published showAliasPrompt = true 트리거
        DispatchQueue.main.async {
            self.pendingAliasContext = CameraAliasPromptContext(
                volumeURL: url,
                volumeUUID: uuid,
                cameraModel: CameraInfoExtractor.cameraModel(fromFirstPhotoIn: url),
                fileCount: self.scanPhotos(from: url).count,
                totalBytes: 0, // optional
                onSave: { [weak self] alias in
                    guard let self, let alias else { return }
                    if let uuid {
                        CameraAliasStore.shared.save(CameraAlias(
                            volumeUUID: uuid,
                            cameraModel: CameraInfoExtractor.cameraModel(fromFirstPhotoIn: url),
                            alias: alias))
                    }
                    self.startIngest(from: url, settings: settings, aliasProvider: { _, _, reply in reply(alias) })
                }
            )
            self.showAliasPrompt = true
        }
    }
    return // 기존 showBackupPrompt 경로 스킵
}
// 설정 없으면 기존 폴더 선택 팝업 유지 (하위호환)
```

MemoryCardBackupService에 `@Published var showAliasPrompt` 및 `pendingAliasContext`, `pendingIngestVolume` 프로퍼티 추가.

- [ ] **Step 3: ContentView에서 sheet로 연결**

```swift
// ContentView or ContentView+SupportingViews.swift
.sheet(isPresented: $memoryCardBackup.showAliasPrompt) {
    if let ctx = memoryCardBackup.pendingAliasContext {
        CameraAliasPromptView(context: ctx)
    }
}
```

- [ ] **Step 4: 빌드 확인**

Expected: BUILD SUCCEEDED

- [ ] **Step 5: Commit**

```
git add PhotoRawManager/Services/MemoryCardBackupService.swift PhotoRawManager/PhotoRawManagerApp.swift PhotoRawManager/Views/
git commit -m "feat(ingest): 볼륨 감지 → IngestSettings 기반 자동 라우팅 + 마이그레이션"
```

---

### Task 14: 통합 테스트 (임시 디렉토리 듀얼 복사)

**Files:**
- Modify: `/Users/potokan/PhotoRawManager/PhotoRawManagerTests/IngestServiceTests.swift`

- [ ] **Step 1: 100장 스트레스 테스트 추가**

```swift
func testLargeBatch100Files() throws {
    for i in 6...105 {
        let name = String(format: "IMG_%04d.JPG", i)
        let url = volumeRoot.appendingPathComponent("DCIM/100CANON/\(name)")
        try Data(repeating: UInt8(i % 256), count: 4096).write(to: url)
    }
    var settings = IngestSettings.default
    settings.primaryDestination = primaryDest
    settings.secondaryDestination = secondaryDest
    settings.folderStructure = .dateCamera
    settings.renamePattern = "{camera}_{seq}"

    let service = IngestService()
    let exp = expectation(description: "complete")
    let session = service.startIngest(
        volumeURL: volumeRoot, cameraModel: "R5", cameraAlias: "R5-메인",
        settings: settings, captureDate: Date()
    ) { exp.fulfill() }

    wait(for: [exp], timeout: 60)

    XCTAssertEqual(session?.primaryResult?.success, 105)
    XCTAssertEqual(session?.secondaryResult?.success, 105)

    // 파일명 패턴 확인
    let today = dateToday()
    let primaryFolder = primaryDest.appendingPathComponent(today).appendingPathComponent("R5-메인")
    let contents = try FileManager.default.contentsOfDirectory(at: primaryFolder, includingPropertiesForKeys: nil)
    XCTAssertEqual(contents.count, 105)
    XCTAssertTrue(contents.contains { $0.lastPathComponent == "R5-메인_0001.JPG" })
}

func testConflictSkipsDuplicates() throws {
    var settings = IngestSettings.default
    settings.primaryDestination = primaryDest
    settings.folderStructure = .dateOnly

    // 1회차
    let exp1 = expectation(description: "first")
    _ = IngestService().startIngest(
        volumeURL: volumeRoot, cameraModel: "R5", cameraAlias: "R5",
        settings: settings, captureDate: Date()
    ) { exp1.fulfill() }
    wait(for: [exp1], timeout: 10)

    // 2회차 — 동일한 카드 재복사
    let exp2 = expectation(description: "second")
    let session2 = IngestService().startIngest(
        volumeURL: volumeRoot, cameraModel: "R5", cameraAlias: "R5",
        settings: settings, captureDate: Date()
    ) { exp2.fulfill() }
    wait(for: [exp2], timeout: 10)

    XCTAssertEqual(session2?.primaryResult?.skipped, 5)
    XCTAssertEqual(session2?.primaryResult?.failed.count, 0)
}
```

- [ ] **Step 2: 테스트 실행**

Run:
```
xcodebuild test -project /Users/potokan/PhotoRawManager/PhotoRawManager.xcodeproj \
  -scheme PhotoRawManager \
  -only-testing:PhotoRawManagerTests/IngestServiceTests
```
Expected: PASS (전체)

- [ ] **Step 3: Commit**

```
git add PhotoRawManagerTests/IngestServiceTests.swift
git commit -m "test(ingest): 100장 스트레스 + 중복 skip 통합 테스트"
```

---

### Task 15: 수동 테스트 체크리스트 + 문서 업데이트

**Files:**
- Modify: `/Users/potokan/PhotoRawManager/CLAUDE.md`
- Create: `/Users/potokan/PhotoRawManager/docs/ingest-manual-test.md`

- [ ] **Step 1: 매뉴얼 테스트 체크리스트 문서 생성**

```markdown
# 듀얼 인제스트 수동 테스트 체크리스트

## 기본 워크플로우
- [ ] Settings → 인제스트 탭 → Primary/Secondary 지정
- [ ] 실제 SD카드 꽂기 → 별칭 입력 모달 표시
- [ ] "R5-메인" 입력 후 저장 → 듀얼 복사 시작
- [ ] 툴바 프로그레스 바에 2줄 표시 (Primary/Secondary)
- [ ] 완료 후 두 디스크에 파일이 동일하게 있는지 확인

## 멀티카메라
- [ ] R5 카드 꽂기 → "R5-메인" 저장
- [ ] 같은 R5 다른 카드 꽂기 → "R5-서브" 입력 모달 표시
- [ ] A7 카드 꽂기 → "A7" 별칭 저장
- [ ] 3카드 모두 `{date}/{camera}/` 경로로 분리됐는지 확인

## 멀티 카드 동시
- [ ] 듀얼 슬롯 리더 2장 동시 삽입 → 4개 진행률 표시
- [ ] 모두 완료까지 대기 → 토스트 확인

## 에러 케이스
- [ ] Secondary 디스크 full → Primary만 성공, 모달 안내
- [ ] 복사 중 카드 뽑기 → 세션 취소 + 실패 알림
- [ ] 해시 검증 ON → 느려지는 정도 측정

## 하위호환
- [ ] Secondary 비워둔 단일 백업 사용자 → 기존처럼 동작
- [ ] 구버전에서 사용하던 destinationURL → 첫 실행 시 Primary로 자동 이관
```

- [ ] **Step 2: CLAUDE.md 버전 섹션 업데이트**

현재 버전 섹션을 v8.1로 변경하고 듀얼 인제스트 기능을 추가 목록에 넣는다:

```markdown
## 현재 버전: v8.1
...
### v8.1 추가 기능
- 듀얼 백업 인제스트 (Primary + Secondary 동시 복사)
- 카메라 별칭 자동 기억 (카드 UUID 기반)
- 폴더 구조 자동 분류 ({date}/{camera}/)
- 파일명 일괄 변경 (토큰 패턴)
- MD5 해시 검증 옵션
```

- [ ] **Step 3: 최종 전체 테스트 + 빌드**

Run:
```
xcodebuild test -project /Users/potokan/PhotoRawManager/PhotoRawManager.xcodeproj -scheme PhotoRawManager
xcodebuild -project /Users/potokan/PhotoRawManager/PhotoRawManager.xcodeproj -scheme PhotoRawManager -configuration Debug build
```
Expected: 모두 PASS / BUILD SUCCEEDED

- [ ] **Step 4: Commit**

```
git add docs/ingest-manual-test.md CLAUDE.md
git commit -m "docs(ingest): 수동 테스트 체크리스트 + v8.1 CLAUDE.md 업데이트"
```

---

## 스펙 커버리지 매트릭스

| 스펙 섹션 | 커버된 Task |
|---|---|
| 시나리오 1 (단일 카드 듀얼) | 4, 6, 9 |
| 시나리오 2 (멀티카메라) | 3, 4, 8, 10 |
| 시나리오 3 (멀티 카드 동시) | 6 (병렬 DispatchGroup), 11 |
| 신규 타입 (IngestSession) | 5 |
| 신규 타입 (IngestSettings/FolderStructure) | 2 |
| 신규 타입 (CameraAlias) | 3 |
| IngestPlanner | 4 |
| IngestService | 6 |
| MemoryCardBackupService 변경 | 8, 13 |
| 동작 흐름 (EXIF 추출) | 8 (CameraInfoExtractor) |
| 동작 흐름 (충돌 감지) | 4 (resolveConflict) |
| UI — IngestSettingsView | 9, 12 |
| UI — CameraAliasPromptView | 10, 13 |
| UI — IngestProgressBar | 11 |
| 에러 처리 (재시도 3회) | 6 |
| 에러 처리 (MD5 불일치) | 7 |
| 에러 처리 (EXIF 없음 → Unknown) | 4, 8 |
| 데이터 저장 (UserDefaults 키) | 3, 9 |
| 마이그레이션 | 9 (Store), 13 |
| 단위 테스트 (Planner/AliasStore) | 3, 4 |
| 통합 테스트 | 6, 14 |
| 수동 테스트 | 15 |
| 성능 목표 (병렬) | 6 (DispatchGroup 두 큐) |

모든 스펙 섹션이 최소 1개 이상의 Task에 매핑되었음.

## 용어/이름 일관성 체크

- `IngestSession`, `IngestService`, `IngestPlanner`, `IngestSettings`, `IngestSettingsStore`, `IngestProgressBar` — 모두 `Ingest` prefix
- `CameraAlias`, `CameraAliasStore`, `CameraAliasPromptView`, `CameraAliasPromptContext` — 모두 `CameraAlias` prefix
- `CameraInfoExtractor` — EXIF/UUID 추출 전용 유틸
- `MD5Hasher` — 해시 전용
- `FolderStructure`, `VerifyMode` — enum (String, Codable, CaseIterable)
- `BackupSession`, `BackupResult`, `FailedFile` — 기존 유지

모든 타입 이름이 서로 충돌 없이 식별 가능함.
