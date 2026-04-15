# PhotoStore 분할 Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** 3,694줄 / 115 @Published짜리 God Object `PhotoStore.swift`를 도메인별 extension 파일 10개로 분할해 유지보수성을 확보한다.

**Architecture:**
클래스를 쪼개지 않는다(뷰 바인딩 `@EnvironmentObject var store: PhotoStore`를 건드리지 않기 위해). 같은 `class PhotoStore`에 속한 기능들을 `extension PhotoStore { ... }` 파일 여러 개로 분리한다. 각 extension 파일은 "도메인 한 개"를 담당한다: Selection / Folder / Rating / Move / Analysis / Export / Exif / UI / Collections. 코어 파일(`PhotoStore.swift`)에는 클래스 선언, 핵심 @Published 저장 속성, `filteredPhotos`, 생성자/필터 캐시만 남긴다. **저장 프로퍼티(`@Published var`)는 extension에 둘 수 없으므로 코어 파일에 남기고, 함수만 extension으로 옮긴다.**

**Tech Stack:** Swift / SwiftUI / Combine / macOS. 기존 패턴 참고: `ContentView+Toolbar.swift`, `ContentView+FolderBrowser.swift`, `ContentView+SupportingViews.swift` (이미 같은 방식으로 분할되어 있음).

**안전장치:**
- 직전 커밋 `d24f1af`가 롤백 지점. 중간에 문제 생기면 `git reset --hard d24f1af`.
- 각 태스크 = 1 extension 파일 = 1 커밋. 빌드 실패 시 해당 커밋만 revert.
- 동작 변경 0. 코드 이동만.

---

## File Structure

코어 파일 1개 + extension 파일 9개 = 총 10개.

| 파일 | 담당 | 예상 줄수 |
|---|---|---|
| `PhotoStore.swift` | 클래스 선언, 모든 @Published 저장 속성, init, filteredPhotos, sortPhotos, invalidateFilterCache, ensureFilteredIndex, updateFolderSizeCache | ~1,100 |
| `PhotoStore+Selection.swift` | selectPhoto, selectAll/deselectAll, moveSelection, selectRight/Left/Up/Down, executeMoveSelection, restoreKeyFocus, rebuildIndex, idx, multiSelectedPhotosLimited, isSelected | ~350 |
| `PhotoStore+Folder.swift` | loadFolder, loadPhotosRecursive, exitRecursiveMode, setupFolderWatcher, handleNewFiles, openFolder, navigateBack/Forward, addToFolderHistory, addRecent/FavoriteFolder, loadRecent/FavoriteFolders, setFavoriteNickname, favoriteNickname, openZipFile, cleanupZipTemp, restoreLastSession, saveLastFolder | ~500 |
| `PhotoStore+Rating.swift` | saveRatings, applySavedRatings, setRating, setRatingForSelected, setColorLabel, setColorLabelForSelected, toggleSpacePick, toggleSpacePickForSelected, undo, pushUndo, ensureRawExifLoaded | ~350 |
| `PhotoStore+Move.swift` | movePhoto, movePhotos, removeSelectedFromList, removePhotosFromList, deleteOriginalFiles, requestDeleteOriginal, deleteSelectedItems, deleteFolders, importFilesFromExternal, movePhotosToFolder, batchRename, undoBatchRename, buildClientComments, importPickshotFile | ~700 |
| `PhotoStore+Analysis.swift` | runQualityAnalysis, runNIMAScoring, findDuplicates, stopAnalysis, classifyScenes, groupByFaces, setFaceGroupName, saveFaceGroupNames, loadFaceGroupNames, faceGroupName, runAIClassification, organizeByAICategory, previewSmartSelect, applySmartSelect | ~800 |
| `PhotoStore+Exif.swift` | loadExifIfNeeded, batchLoadExif, exifFor, livePhoto, triggerListExifLoad, preloadThumbnailsAroundSelection, preloadAllThumbnails, prefetchNearby, prefetchThumbnailsBoth, prefetchNearbyThumbnails, startIdlePreviewPrefetch, reverseGeocodeIfNeeded, applyPhotosUpdate | ~350 |
| `PhotoStore+UI.swift` | setLayoutMode, recalcColumnsFromRatio, showToastMessage, toggleMetadataOverlay | ~80 |
| `PhotoStore+Collections.swift` | saveCurrentFilter, applyCollection, deleteCollection, saveCollections, loadCollections, applySettingsFromDefaults, autoOptimizeOnFirstLaunch | ~150 |

총 ~4,380줄이 나뉘어 각 파일 평균 ~440줄. 코어는 저장 속성 때문에 1,100줄 정도로 큼 (필수).

---

## 원칙 (모든 태스크 공통)

1. **저장 속성 이동 금지.** `@Published var`, `var`, `let` 저장 속성은 `PhotoStore.swift`에 그대로 둔다. extension이 저장 속성을 선언하면 컴파일 에러(Swift 언어 제약).
2. **`private` 함수는 `fileprivate`로 바꾼다.** `private func foo()`를 extension 파일로 옮기면 다른 파일에서 호출 못 함. 호출자가 같은 파일 안에 있는 함수만 `private` 유지 가능. 잘 모르겠으면 안전하게 `fileprivate` 또는 `internal`(기본값) 로 변경.
3. **지정 이니셜라이저 금지.** extension은 `convenience init`만 가능. init은 코어에 둔다.
4. **`didSet` / `willSet` 은 저장 속성 선언과 붙어 있어야 한다** → 코어 파일에 남는다.
5. **각 extension 파일 헤더:**
   ```swift
   import SwiftUI
   import Combine
   // 필요한 import만 추가 (AppKit, Vision 등)

   extension PhotoStore {
       // 함수들
   }
   ```
6. **Xcode 프로젝트에 새 파일 추가 필수.** `project.pbxproj`에 PBXFileReference + PBXBuildFile + PBXGroup 항목을 추가해야 빌드에 포함된다. `PhotoRawManager/Models/` 폴더와 같은 그룹에 넣는다.
7. **각 태스크 마지막에 반드시 전체 빌드.** 한 번에 한 파일씩 이동 → 빌드 성공 확인 → 커밋. 빌드 깨지면 `git reset --hard HEAD` 또는 직전 커밋으로 롤백.

---

## 공통 검증 명령

빌드 명령(모든 태스크의 "Step: Build & verify"에서 동일하게 사용):

```bash
cd /Users/potokan/PhotoRawManager && xcodebuild -project PhotoRawManager.xcodeproj -scheme PhotoRawManager -configuration Debug build 2>&1 | tail -30
```

Expected: `** BUILD SUCCEEDED **` 와 함께 끝남. 한 줄이라도 `error:` 가 나오면 실패.

---

## Task 0: 사전 확인 (코드 이동 없음)

**Files:** 없음 (읽기만)

- [ ] **Step 1: 현재 커밋 위치 기록**

```bash
cd /Users/potokan/PhotoRawManager && git log --oneline -1
```

Expected: `d24f1af refactor: 테스터 피드백 마무리 + 쓰레기 코드 정리`

이 해시가 전체 분할 작업의 롤백 지점. 어느 태스크에서든 문제 생기면:
```bash
git reset --hard d24f1af
```
로 전부 되돌아간다.

- [ ] **Step 2: 베이스라인 빌드 성공 확인**

```bash
cd /Users/potokan/PhotoRawManager && xcodebuild -project PhotoRawManager.xcodeproj -scheme PhotoRawManager -configuration Debug build 2>&1 | tail -10
```

Expected: `** BUILD SUCCEEDED **`

만약 이 시점에 빌드가 실패하면 이 플랜을 진행하지 말 것. 먼저 현재 빌드를 고쳐야 함.

- [ ] **Step 3: PhotoStore 줄수/함수 목록 스냅샷**

```bash
cd /Users/potokan/PhotoRawManager && wc -l PhotoRawManager/Models/PhotoStore.swift
```

Expected: `3694 PhotoRawManager/Models/PhotoStore.swift` 근처 (다른 작업으로 약간 다를 수 있으나 ±50 이내여야 함).

차이가 크면 이전 대화의 변경사항이 누락된 것. 확인 필요.

---

## Task 1: PhotoStore+Collections.swift 추출 (가장 작은 것부터)

가장 단순하고 의존성 적은 도메인부터 시작해 프로세스를 검증한다.

**Files:**
- Create: `PhotoRawManager/Models/PhotoStore+Collections.swift`
- Modify: `PhotoRawManager/Models/PhotoStore.swift` (함수 제거)
- Modify: `PhotoRawManager.xcodeproj/project.pbxproj` (새 파일 등록)

**이동 대상 함수:**
- `saveCurrentFilter(name:)` (라인 407~)
- `applyCollection(_:)` (라인 420~)
- `deleteCollection(_:)` (라인 433~)
- `saveCollections()` (라인 437~, `private` → `fileprivate`로 변경)
- `loadCollections()` (라인 443~)
- `applySettingsFromDefaults()` (라인 650~)
- `autoOptimizeOnFirstLaunch()` (라인 564~, `private` → `fileprivate`로 변경)

**남기는 것 (코어에 유지):**
- `@Published var savedCollections: [SmartCollection]` (저장 속성)
- `@Published var searchText: String` (저장 속성)

- [ ] **Step 1: 이동할 함수 본문 확인**

```bash
cd /Users/potokan/PhotoRawManager && grep -n "func saveCurrentFilter\|func applyCollection\|func deleteCollection\|func saveCollections\|func loadCollections\|func applySettingsFromDefaults\|func autoOptimizeOnFirstLaunch" PhotoRawManager/Models/PhotoStore.swift
```

Expected: 7개 함수의 라인 번호가 출력됨.

- [ ] **Step 2: 새 파일 생성**

파일 `/Users/potokan/PhotoRawManager/PhotoRawManager/Models/PhotoStore+Collections.swift` 작성. 본문은 다음 구조:

```swift
import SwiftUI
import Foundation

extension PhotoStore {
    func saveCurrentFilter(name: String) {
        // PhotoStore.swift에서 그대로 복사한 본문
    }

    func applyCollection(_ col: SmartCollection) {
        // PhotoStore.swift에서 그대로 복사한 본문
    }

    func deleteCollection(_ id: UUID) {
        // PhotoStore.swift에서 그대로 복사한 본문
    }

    fileprivate func saveCollections() {
        // PhotoStore.swift에서 그대로 복사한 본문. `private` → `fileprivate`
    }

    func loadCollections() {
        // PhotoStore.swift에서 그대로 복사한 본문
    }

    func applySettingsFromDefaults() {
        // PhotoStore.swift에서 그대로 복사한 본문
    }

    fileprivate func autoOptimizeOnFirstLaunch() {
        // PhotoStore.swift에서 그대로 복사한 본문. `private` → `fileprivate`
    }
}
```

각 함수 본문은 `PhotoStore.swift`에서 그대로 복사. **절대 바꾸지 말 것.** `private` → `fileprivate` 변경만 적용.

- [ ] **Step 3: PhotoStore.swift에서 이동한 함수 제거**

위 7개 함수를 `PhotoStore.swift`에서 잘라내 버린다. `@Published var savedCollections`, `@Published var searchText` 선언은 **유지**.

- [ ] **Step 4: Xcode 프로젝트에 새 파일 등록**

`PhotoRawManager.xcodeproj/project.pbxproj`를 편집해 새 파일 등록:

1. `PBXFileReference` 섹션에 추가 (기존 PhotoStore.swift 엔트리 옆):
   ```
   PS20001 /* PhotoStore+Collections.swift */ = {isa = PBXFileReference; lastKnownFileType = sourcecode.swift; path = "PhotoStore+Collections.swift"; sourceTree = "<group>"; };
   ```
2. `PBXBuildFile` 섹션에 추가:
   ```
   PS20002 /* PhotoStore+Collections.swift in Sources */ = {isa = PBXBuildFile; fileRef = PS20001 /* PhotoStore+Collections.swift */; };
   ```
3. `Models` 그룹의 `children` 배열에 `PS20001` 추가 (PhotoStore.swift 바로 밑에).
4. `PBXSourcesBuildPhase`의 `files` 배열에 `PS20002` 추가.

정확한 위치는 기존 `PhotoStore.swift` 항목을 찾아 그 근처에 같은 형식으로 추가한다. ID는 충돌 방지를 위해 `PS20001`, `PS20002`처럼 프로젝트에서 안 쓰는 문자열로.

- [ ] **Step 5: 빌드 & 검증**

```bash
cd /Users/potokan/PhotoRawManager && xcodebuild -project PhotoRawManager.xcodeproj -scheme PhotoRawManager -configuration Debug build 2>&1 | tail -30
```

Expected: `** BUILD SUCCEEDED **`

실패 시:
- `Cannot find 'saveCollections' in scope` → `private` 제거 빠진 것. `fileprivate`로 바꿔라.
- `Build input file cannot be found: PhotoStore+Collections.swift` → pbxproj의 파일 등록 실패. Step 4 다시.
- `Invalid redeclaration` → 함수가 양쪽 파일에 다 있음. PhotoStore.swift에서 제거 안 된 것.

- [ ] **Step 6: 스모크 테스트 (수동)**

앱 실행:
```bash
cd /Users/potokan/PhotoRawManager && xcodebuild -project PhotoRawManager.xcodeproj -scheme PhotoRawManager -configuration Debug build 2>&1 >/tmp/pickshot_debug.log; open -a PhotoRawManager.app ~/Pictures
```

확인할 것:
- 앱이 실행되나
- 폴더 열림 / 썸네일 표시됨
- 설정 > 스마트 컬렉션 관련 UI 열림 (자동 적용되는 값 `applySettingsFromDefaults` 동작 포함)

문제 있으면: `git reset --hard HEAD~0` 은 의미 없으니 변경된 3개 파일 수동 원복 또는 `git stash`.

- [ ] **Step 7: 커밋**

```bash
cd /Users/potokan/PhotoRawManager && git add PhotoRawManager/Models/PhotoStore.swift PhotoRawManager/Models/PhotoStore+Collections.swift PhotoRawManager.xcodeproj/project.pbxproj
git commit -m "$(cat <<'EOF'
refactor(PhotoStore): Collections/Settings 함수를 extension 파일로 분리

- PhotoStore+Collections.swift 신설 (7 functions, ~150 lines)
- savedCollections / searchText 저장 속성은 코어에 유지
- private → fileprivate 2곳 변경 (saveCollections, autoOptimizeOnFirstLaunch)

PhotoStore 분할 1/9.

Co-Authored-By: Claude Opus 4.6 <noreply@anthropic.com>
EOF
)"
```

---

## Task 2: PhotoStore+UI.swift 추출

**Files:**
- Create: `PhotoRawManager/Models/PhotoStore+UI.swift`
- Modify: `PhotoRawManager/Models/PhotoStore.swift`
- Modify: `PhotoRawManager.xcodeproj/project.pbxproj`

**이동 대상 함수:**
- `setLayoutMode(_:)` (라인 661~)
- `recalcColumnsFromRatio()` (라인 2611~)
- `showToastMessage(_:)` (라인 302~)
- `toggleMetadataOverlay()` (라인 3468~)

**남기는 것:**
- 모든 `show*` @Published, `isDarkMode`, `previewBgMode`, `previewBgCustomHex`, `layoutMode`, `hSplitRatio`, `vSplitRatio`, `actualColumnsPerRow`, `thumbnailSize`, `toastMessage`, `showToast` (저장 속성이므로 이동 불가)

- [ ] **Step 1: 이동 대상 함수 위치 확인**

```bash
cd /Users/potokan/PhotoRawManager && grep -n "func setLayoutMode\|func recalcColumnsFromRatio\|func showToastMessage\|func toggleMetadataOverlay" PhotoRawManager/Models/PhotoStore.swift
```

Expected: 4개 라인.

- [ ] **Step 2: 새 파일 생성**

`/Users/potokan/PhotoRawManager/PhotoRawManager/Models/PhotoStore+UI.swift`:

```swift
import SwiftUI
import Foundation

extension PhotoStore {
    func showToastMessage(_ msg: String) {
        // 복사한 본문
    }

    func setLayoutMode(_ mode: LayoutMode) {
        // 복사한 본문
    }

    func recalcColumnsFromRatio() {
        // 복사한 본문
    }

    func toggleMetadataOverlay() {
        // 복사한 본문
    }
}
```

- [ ] **Step 3: PhotoStore.swift에서 제거**

위 4개 함수만 삭제. 저장 속성은 그대로.

- [ ] **Step 4: pbxproj 등록**

Task 1 Step 4와 동일한 절차. ID는 `PS20003`, `PS20004`.

- [ ] **Step 5: 빌드 & 검증**

공통 빌드 명령 실행. Expected: `** BUILD SUCCEEDED **`

- [ ] **Step 6: 커밋**

```bash
cd /Users/potokan/PhotoRawManager && git add PhotoRawManager/Models/PhotoStore.swift PhotoRawManager/Models/PhotoStore+UI.swift PhotoRawManager.xcodeproj/project.pbxproj
git commit -m "$(cat <<'EOF'
refactor(PhotoStore): UI 관련 함수를 extension 파일로 분리

- PhotoStore+UI.swift 신설 (setLayoutMode, recalcColumnsFromRatio, showToastMessage, toggleMetadataOverlay)
- 모든 @Published show*/layout/split 저장 속성은 코어 유지

PhotoStore 분할 2/9.

Co-Authored-By: Claude Opus 4.6 <noreply@anthropic.com>
EOF
)"
```

---

## Task 3: PhotoStore+Exif.swift 추출

**Files:**
- Create: `PhotoRawManager/Models/PhotoStore+Exif.swift`
- Modify: `PhotoRawManager/Models/PhotoStore.swift`
- Modify: `PhotoRawManager.xcodeproj/project.pbxproj`

**이동 대상 (모두 `private` → `fileprivate` 또는 `internal`로 변경 검토):**
- `applyPhotosUpdate(_:)` (라인 1576~, `private` → `fileprivate`)
- `exifFor(_:)` (라인 2085~)
- `livePhoto(_:)` (라인 2090~)
- `loadExifIfNeeded(for:)` (라인 2095~)
- `triggerListExifLoad()` (라인 2133~)
- `batchLoadExif(count:)` (라인 1953~)
- `reverseGeocodeIfNeeded(for:)` (라인 1987~)
- `preloadAllThumbnails()` (라인 2145~, `private` → `fileprivate`)
- `startIdlePreviewPrefetch()` (라인 2157~)
- `preloadThumbnailsAroundSelection(initialLoad:)` (라인 2235~)
- `prefetchNearby(list:centerIndex:range:)` (라인 2720~, `private` → `fileprivate`)
- `prefetchThumbnailsBoth(list:centerIndex:count:)` (라인 2778~, `private` → `fileprivate`)
- `prefetchNearbyThumbnails()` (라인 733~, `private` → `fileprivate`)
- `ensureRawExifLoaded(for:)` (라인 781~) ← **주의: Rating 파일에도 관련, 하지만 EXIF 로딩이므로 여기**

⚠️ **주의:** `applyPhotosUpdate`는 `photos`의 `didSet`에서 호출된다. `didSet`은 저장 속성이므로 코어에 남고, 거기서 `applyPhotosUpdate`를 호출한다. `fileprivate`로 바꾸면 다른 파일에서 호출 불가 → 코어에서 호출하려면 `internal`(기본값)이어야 한다. **`applyPhotosUpdate`는 `private` 키워드를 제거해 `internal`로 만든다.** 마찬가지로 `preloadAllThumbnails`, `prefetchNearby`, `prefetchThumbnailsBoth`, `prefetchNearbyThumbnails` 중 다른 파일의 함수가 호출하는 것은 `internal`.

- [ ] **Step 1: 호출부 조사**

```bash
cd /Users/potokan/PhotoRawManager && grep -n "applyPhotosUpdate\|preloadAllThumbnails\|prefetchNearby\|prefetchThumbnailsBoth\|prefetchNearbyThumbnails" PhotoRawManager/Models/PhotoStore.swift
```

Expected: 호출 지점 목록이 나옴. 호출자가 어느 파일/위치에 있는지 확인해 적절한 접근 수준 결정.

- [ ] **Step 2: 새 파일 생성**

`/Users/potokan/PhotoRawManager/PhotoRawManager/Models/PhotoStore+Exif.swift`:

```swift
import SwiftUI
import Foundation
import ImageIO
import CoreLocation

extension PhotoStore {
    // 위 14개 함수 본문을 그대로 복사
    // `private` 전부 제거하거나 `fileprivate` 변경
}
```

- [ ] **Step 3: PhotoStore.swift에서 제거**

위 14개 함수만 삭제.

- [ ] **Step 4: pbxproj 등록** (ID: PS20005, PS20006)

- [ ] **Step 5: 빌드 & 검증**

공통 빌드. Expected: `** BUILD SUCCEEDED **`

실패 시 주요 원인:
- `'private' method ... inaccessible` → `fileprivate`/`internal`로 바꿔야 함
- `didSet cannot call ... method on self` → 호출하는 함수가 `private` → 코어에서 접근 불가. `internal`로.

- [ ] **Step 6: 스모크 테스트**

앱 실행 후:
- 폴더 열기 → 썸네일 떠야 함 (preloadAllThumbnails)
- 선택 이동 시 근처 프리뷰 로딩 되어야 함 (preloadThumbnailsAroundSelection)
- EXIF 정보 표시되어야 함 (loadExifIfNeeded)

- [ ] **Step 7: 커밋**

```bash
cd /Users/potokan/PhotoRawManager && git add PhotoRawManager/Models/PhotoStore.swift PhotoRawManager/Models/PhotoStore+Exif.swift PhotoRawManager.xcodeproj/project.pbxproj
git commit -m "$(cat <<'EOF'
refactor(PhotoStore): EXIF/썸네일 프리페치 함수 분리

- PhotoStore+Exif.swift 신설 (14 functions, ~350 lines)
- applyPhotosUpdate를 internal로 승격 (didSet에서 호출)
- prefetch 계열 private → fileprivate/internal

PhotoStore 분할 3/9.

Co-Authored-By: Claude Opus 4.6 <noreply@anthropic.com>
EOF
)"
```

---

## Task 4: PhotoStore+Rating.swift 추출

**Files:**
- Create: `PhotoRawManager/Models/PhotoStore+Rating.swift`
- Modify: `PhotoRawManager/Models/PhotoStore.swift`
- Modify: `PhotoRawManager.xcodeproj/project.pbxproj`

**이동 대상:**
- `pushUndo(action:photoIDs:)` (라인 467~, `private` → `fileprivate`)
- `undo()` (라인 484~)
- `saveRatings()` (라인 785~, `private` → `fileprivate`)
- `applySavedRatings()` (라인 819~, `private` → `fileprivate`)
- `setColorLabel(_:for:)` (라인 1482~)
- `setColorLabelForSelected(_:)` (라인 1490~)
- `toggleSpacePick(for:)` (라인 1499~)
- `toggleSpacePickForSelected()` (라인 1508~)
- `setRatingForSelected(_:)` (라인 1546~)
- `setRating(_:for:)` (라인 2417~)

- [ ] **Step 1: 호출부 조사**

```bash
cd /Users/potokan/PhotoRawManager && grep -n "pushUndo\|saveRatings\|applySavedRatings" PhotoRawManager/Models/PhotoStore.swift
```

Expected: 여러 호출. `saveRatings`는 Rating 변경마다 호출됨.

- [ ] **Step 2: 새 파일 생성**

`/Users/potokan/PhotoRawManager/PhotoRawManager/Models/PhotoStore+Rating.swift`:

```swift
import SwiftUI
import Foundation

extension PhotoStore {
    // 10개 함수 복사
}
```

- [ ] **Step 3: PhotoStore.swift에서 제거**

- [ ] **Step 4: pbxproj 등록** (ID: PS20007, PS20008)

- [ ] **Step 5: 빌드 & 검증**

공통 빌드. Expected: `** BUILD SUCCEEDED **`

- [ ] **Step 6: 스모크 테스트**

- 별점 1~5 키 눌러 설정 → 셀에 별 표시됨
- 스페이스 → 빨간 점 토글
- 컬러 라벨 단축키 동작
- Cmd+Z → 직전 별점 복구

- [ ] **Step 7: 커밋**

```bash
cd /Users/potokan/PhotoRawManager && git add PhotoRawManager/Models/PhotoStore.swift PhotoRawManager/Models/PhotoStore+Rating.swift PhotoRawManager.xcodeproj/project.pbxproj
git commit -m "$(cat <<'EOF'
refactor(PhotoStore): 별점/컬러라벨/Undo 함수 분리

- PhotoStore+Rating.swift 신설 (10 functions, ~350 lines)

PhotoStore 분할 4/9.

Co-Authored-By: Claude Opus 4.6 <noreply@anthropic.com>
EOF
)"
```

---

## Task 5: PhotoStore+Selection.swift 추출

**Files:**
- Create: `PhotoRawManager/Models/PhotoStore+Selection.swift`
- Modify: `PhotoRawManager/Models/PhotoStore.swift`
- Modify: `PhotoRawManager.xcodeproj/project.pbxproj`

**이동 대상:**
- `rebuildIndex()` (라인 889~)
- `multiSelectedPhotosLimited(_:)` (라인 915~)
- `restoreKeyFocus()` (라인 935~)
- `selectPhoto(_:cmdKey:shiftKey:)` (라인 952~)
- `selectAll()` (라인 1024~)
- `deselectAll()` (라인 1030~)
- `idx(_:)` (라인 1477~)
- `isSelected(_:)` (라인 1556~)
- `ensureFilteredIndex()` (라인 2636~, `private` → `fileprivate`) ← **주의: filteredPhotos 의존**
- `moveSelection(by:shiftKey:cmdKey:)` (라인 2657~, `private` → `fileprivate`)
- `executeMoveSelection(by:shiftKey:cmdKey:)` (라인 2661~, `private` → `fileprivate`)
- `selectRight/Left/Down/Up` (라인 2808~)

**주의: `ensureFilteredIndex`가 `filteredPhotos`를 사용한다. `filteredPhotos`는 코어에 남는 computed property.** Extension에서 코어의 computed 접근은 가능.

- [ ] **Step 1: 이동 대상 확인**

```bash
cd /Users/potokan/PhotoRawManager && grep -n "func rebuildIndex\|func multiSelectedPhotosLimited\|func restoreKeyFocus\|func selectPhoto\|func selectAll\|func deselectAll\|func idx\|func isSelected\|func ensureFilteredIndex\|func moveSelection\|func executeMoveSelection\|func selectRight\|func selectLeft\|func selectDown\|func selectUp" PhotoRawManager/Models/PhotoStore.swift
```

Expected: 13개 함수.

- [ ] **Step 2: 새 파일 생성**

`/Users/potokan/PhotoRawManager/PhotoRawManager/Models/PhotoStore+Selection.swift`:

```swift
import SwiftUI
import Foundation

extension PhotoStore {
    // 13개 함수 복사
}
```

- [ ] **Step 3: PhotoStore.swift에서 제거**

- [ ] **Step 4: pbxproj 등록** (ID: PS20009, PS20010)

- [ ] **Step 5: 빌드 & 검증**

공통 빌드. Expected: `** BUILD SUCCEEDED **`

- [ ] **Step 6: 스모크 테스트**

- 썸네일 클릭 → 선택 테두리
- Cmd+클릭 → 다중 선택
- Shift+클릭 → 범위 선택
- 화살표 키 → 선택 이동
- Cmd+A → 전체 선택

- [ ] **Step 7: 커밋**

```bash
cd /Users/potokan/PhotoRawManager && git add PhotoRawManager/Models/PhotoStore.swift PhotoRawManager/Models/PhotoStore+Selection.swift PhotoRawManager.xcodeproj/project.pbxproj
git commit -m "$(cat <<'EOF'
refactor(PhotoStore): 선택/키보드 이동 함수 분리

- PhotoStore+Selection.swift 신설 (13 functions, ~350 lines)

PhotoStore 분할 5/9.

Co-Authored-By: Claude Opus 4.6 <noreply@anthropic.com>
EOF
)"
```

---

## Task 6: PhotoStore+Folder.swift 추출

**Files:**
- Create: `PhotoRawManager/Models/PhotoStore+Folder.swift`
- Modify: `PhotoRawManager/Models/PhotoStore.swift`
- Modify: `PhotoRawManager.xcodeproj/project.pbxproj`

**이동 대상:**
- `setupFolderWatcher()` (라인 668~, `private` → `fileprivate`)
- `handleNewFiles(_:)` (라인 687~, `private` → `fileprivate`)
- `restoreLastSession()` (라인 767~, `private` → `fileprivate`)
- `saveLastFolder()` (라인 774~, `private` → `fileprivate`)
- `loadFolder(_:restoreRatings:)` (라인 1734~)
- `loadPhotosRecursive(from:)` (라인 1860~)
- `exitRecursiveMode()` (라인 1941~)
- `openZipFile(_:)` (라인 2046~)
- `cleanupZipTemp()` (라인 2078~)
- `openFolder()` (라인 2427~)
- `navigateBack()` (라인 2441~)
- `navigateForward()` (라인 2448~)
- `addToFolderHistory(_:)` (라인 2455~)
- `addRecentFolder(_:)` (라인 2469~)
- `loadRecentFolders()` (라인 2477~)
- `addFavoriteFolder(_:)` (라인 2484~)
- `removeFavoriteFolder(_:)` (라인 2491~)
- `loadFavoriteFolders()` (라인 2497~)
- `setFavoriteNickname(_:name:)` (라인 2505~)
- `favoriteNickname(for:)` (라인 2515~)
- `updateFolderSizeCache()` (라인 106~, `private` → `fileprivate`) ← **주의: `photos.didSet`에서 호출. `private`을 `internal`로.**

- [ ] **Step 1: 호출부 조사**

```bash
cd /Users/potokan/PhotoRawManager && grep -n "updateFolderSizeCache\|setupFolderWatcher\|restoreLastSession\|saveLastFolder\|handleNewFiles" PhotoRawManager/Models/PhotoStore.swift
```

Expected: didSet, init, 기타 호출자 확인. `updateFolderSizeCache`가 didSet에서 불리면 `internal`.

- [ ] **Step 2: 새 파일 생성**

`/Users/potokan/PhotoRawManager/PhotoRawManager/Models/PhotoStore+Folder.swift`:

```swift
import SwiftUI
import Foundation
import AppKit

extension PhotoStore {
    // 21개 함수 복사
}
```

- [ ] **Step 3: PhotoStore.swift에서 제거**

- [ ] **Step 4: pbxproj 등록** (ID: PS20011, PS20012)

- [ ] **Step 5: 빌드 & 검증**

공통 빌드. Expected: `** BUILD SUCCEEDED **`

- [ ] **Step 6: 스모크 테스트**

- 폴더 열기 → 사진 로드
- 즐겨찾기 추가/제거
- 최근 폴더 네비게이션 (뒤/앞)
- ZIP 열기

- [ ] **Step 7: 커밋**

```bash
cd /Users/potokan/PhotoRawManager && git add PhotoRawManager/Models/PhotoStore.swift PhotoRawManager/Models/PhotoStore+Folder.swift PhotoRawManager.xcodeproj/project.pbxproj
git commit -m "$(cat <<'EOF'
refactor(PhotoStore): 폴더 로딩/히스토리/즐겨찾기 함수 분리

- PhotoStore+Folder.swift 신설 (21 functions, ~500 lines)
- updateFolderSizeCache private → internal (photos.didSet 호출)

PhotoStore 분할 6/9.

Co-Authored-By: Claude Opus 4.6 <noreply@anthropic.com>
EOF
)"
```

---

## Task 7: PhotoStore+Move.swift 추출

**Files:**
- Create: `PhotoRawManager/Models/PhotoStore+Move.swift`
- Modify: `PhotoRawManager/Models/PhotoStore.swift`
- Modify: `PhotoRawManager.xcodeproj/project.pbxproj`

**이동 대상:**
- `removeSelectedFromList()` (라인 1035~)
- `removePhotosFromList(ids:)` (라인 1138~)
- `deleteOriginalFiles(ids:)` (라인 1144~)
- `deleteFolders(ids:)` (라인 1217~)
- `requestDeleteOriginal(ids:)` (라인 1245~)
- `deleteSelectedItems()` (라인 1272~)
- `importFilesFromExternal(urls:moveInstead:)` (라인 1294~)
- `movePhotosToFolder(fileURLs:destination:)` (라인 1397~)
- `importPickshotFile()` (라인 1524~)
- `buildClientComments()` (라인 1536~)
- `movePhoto(from:to:)` (라인 2527~)
- `movePhotos(_:to:insertBefore:)` (라인 2569~)
- `batchRename(pattern:)` (라인 3555~)
- `batchRename(pattern:dateFormat:seqDigits:seqStart:preserveRatings:)` (라인 3559~)
- `undoBatchRename()` (라인 3652~)

- [ ] **Step 1: 이동 대상 확인**

```bash
cd /Users/potokan/PhotoRawManager && grep -n "func removeSelectedFromList\|func removePhotosFromList\|func deleteOriginalFiles\|func deleteFolders\|func requestDeleteOriginal\|func deleteSelectedItems\|func importFilesFromExternal\|func movePhotosToFolder\|func importPickshotFile\|func buildClientComments\|func movePhoto\|func movePhotos\|func batchRename\|func undoBatchRename" PhotoRawManager/Models/PhotoStore.swift
```

Expected: 15개 함수.

- [ ] **Step 2: 새 파일 생성**

`/Users/potokan/PhotoRawManager/PhotoRawManager/Models/PhotoStore+Move.swift`:

```swift
import SwiftUI
import Foundation
import AppKit

extension PhotoStore {
    // 15개 함수 복사
}
```

- [ ] **Step 3: PhotoStore.swift에서 제거**

- [ ] **Step 4: pbxproj 등록** (ID: PS20013, PS20014)

- [ ] **Step 5: 빌드 & 검증**

공통 빌드. Expected: `** BUILD SUCCEEDED **`

- [ ] **Step 6: 스모크 테스트**

- 선택 삭제 (Delete 키) → 목록에서 제거
- 드래그 리오더 → 순서 변경
- 배치 리네임 실행 → 파일명 변경
- 외부 파일 드롭 → 가져오기

- [ ] **Step 7: 커밋**

```bash
cd /Users/potokan/PhotoRawManager && git add PhotoRawManager/Models/PhotoStore.swift PhotoRawManager/Models/PhotoStore+Move.swift PhotoRawManager.xcodeproj/project.pbxproj
git commit -m "$(cat <<'EOF'
refactor(PhotoStore): 파일 이동/삭제/리네임/가져오기 함수 분리

- PhotoStore+Move.swift 신설 (15 functions, ~700 lines)

PhotoStore 분할 7/9.

Co-Authored-By: Claude Opus 4.6 <noreply@anthropic.com>
EOF
)"
```

---

## Task 8: PhotoStore+Analysis.swift 추출 (가장 큼)

**Files:**
- Create: `PhotoRawManager/Models/PhotoStore+Analysis.swift`
- Modify: `PhotoRawManager/Models/PhotoStore.swift`
- Modify: `PhotoRawManager.xcodeproj/project.pbxproj`

**이동 대상:**
- `setFaceGroupName(_:name:)` (라인 2017~)
- `faceGroupName(for:)` (라인 2022~)
- `saveFaceGroupNames()` (라인 2026~, `private` → `fileprivate`)
- `loadFaceGroupNames()` (라인 2033~)
- `runQualityAnalysis()` (라인 2276~)
- `runNIMAScoring()` (라인 2336~, `private` → `fileprivate`)
- `findDuplicates()` (라인 2366~)
- `stopAnalysis()` (라인 2391~)
- `previewSmartSelect()` (라인 2397~)
- `applySmartSelect()` (라인 2401~)
- `classifyScenes()` (라인 3022~)
- `groupByFaces()` (라인 3152~)
- `runAIClassification(customPrompt:selectedOnly:)` (라인 3234~)
- `organizeByAICategory()` (라인 3403~)

- [ ] **Step 1: 이동 대상 확인**

```bash
cd /Users/potokan/PhotoRawManager && grep -n "func setFaceGroupName\|func faceGroupName\|func saveFaceGroupNames\|func loadFaceGroupNames\|func runQualityAnalysis\|func runNIMAScoring\|func findDuplicates\|func stopAnalysis\|func previewSmartSelect\|func applySmartSelect\|func classifyScenes\|func groupByFaces\|func runAIClassification\|func organizeByAICategory" PhotoRawManager/Models/PhotoStore.swift
```

Expected: 14개 함수.

- [ ] **Step 2: 새 파일 생성**

`/Users/potokan/PhotoRawManager/PhotoRawManager/Models/PhotoStore+Analysis.swift`:

```swift
import SwiftUI
import Foundation
import Vision
import CoreImage

extension PhotoStore {
    // 14개 함수 복사
}
```

- [ ] **Step 3: PhotoStore.swift에서 제거**

이게 제일 무겁다. 한 번에 옮기지 말고 중간중간 빌드 확인 권장:
- 품질/NIMA 4개 먼저 이동 → 빌드
- 씬/얼굴 그룹 5개 이동 → 빌드
- AI 분류 + 스마트셀렉트 5개 이동 → 빌드
- 최종 커밋

- [ ] **Step 4: pbxproj 등록** (ID: PS20015, PS20016)

- [ ] **Step 5: 빌드 & 검증**

공통 빌드. Expected: `** BUILD SUCCEEDED **`

- [ ] **Step 6: 스모크 테스트**

- 품질 분석 실행 → 진행률 표시 → 완료 시 배지 표시
- 씬 분류 실행 → 태그 부여
- 얼굴 그룹핑 실행 → 인물별 그룹
- 스마트 셀렉트 미리보기 → 추천 표시

- [ ] **Step 7: 커밋**

```bash
cd /Users/potokan/PhotoRawManager && git add PhotoRawManager/Models/PhotoStore.swift PhotoRawManager/Models/PhotoStore+Analysis.swift PhotoRawManager.xcodeproj/project.pbxproj
git commit -m "$(cat <<'EOF'
refactor(PhotoStore): 분석/씬/얼굴/AI/스마트셀렉트 함수 분리

- PhotoStore+Analysis.swift 신설 (14 functions, ~800 lines)

PhotoStore 분할 8/9.

Co-Authored-By: Claude Opus 4.6 <noreply@anthropic.com>
EOF
)"
```

---

## Task 9: 정리 및 최종 검증

**Files:**
- Modify: `PhotoRawManager/Models/PhotoStore.swift` (남은 거 정리)

- [ ] **Step 1: 최종 줄수 확인**

```bash
cd /Users/potokan/PhotoRawManager && wc -l PhotoRawManager/Models/PhotoStore*.swift
```

Expected (근사치):
```
  1100 PhotoStore.swift
   350 PhotoStore+Selection.swift
   500 PhotoStore+Folder.swift
   350 PhotoStore+Rating.swift
   700 PhotoStore+Move.swift
   800 PhotoStore+Analysis.swift
   350 PhotoStore+Exif.swift
    80 PhotoStore+UI.swift
   150 PhotoStore+Collections.swift
  4380 total
```

코어가 1100줄을 크게 넘으면 (예: 1500+) 뭔가 안 옮겨진 것. `grep -c "    func " PhotoStore.swift`로 확인.

- [ ] **Step 2: 코어 파일 남아있는 함수 목록 점검**

```bash
cd /Users/potokan/PhotoRawManager && grep -n "^    func \|^    private func \|^    fileprivate func \|^    internal func " PhotoRawManager/Models/PhotoStore.swift
```

Expected: 다음과 같은 "코어에 남아 있어야 할" 함수들만 남음:
- `invalidateCache()` (썸네일/프리뷰 캐시 무효화)
- `invalidateFilterCache()` (필터 캐시 무효화)
- `sortPhotos(_:)` (정렬 로직 — filteredPhotos 계산에 필수)
- `init()` (지정 이니셜라이저)
- `didSet` 블록들 내부에서만 쓰이는 헬퍼가 있으면 여기

그 외의 함수가 남아있으면 적절한 extension 파일로 이동.

- [ ] **Step 3: 전체 빌드**

공통 빌드. Expected: `** BUILD SUCCEEDED **`

- [ ] **Step 4: 릴리즈 빌드 테스트**

```bash
cd /Users/potokan/PhotoRawManager && xcodebuild -project PhotoRawManager.xcodeproj -scheme PhotoRawManager -configuration Release build 2>&1 | tail -30
```

Expected: `** BUILD SUCCEEDED **`

Debug에서는 안 잡히고 Release에서 잡히는 오류(최적화 관련)가 있을 수 있음.

- [ ] **Step 5: 전체 스모크 테스트**

```bash
cd /Users/potokan/PhotoRawManager && xcodebuild -project PhotoRawManager.xcodeproj -scheme PhotoRawManager -configuration Debug build 2>&1 >/tmp/pickshot_debug.log
```

앱 실행 후 체크리스트:
- [ ] 폴더 열기 → 썸네일 즉시 표시
- [ ] 별점 1~5 설정 → 셀에 반영
- [ ] 스페이스 → 셀렉 토글
- [ ] 컬러 라벨 → 반영
- [ ] Cmd+Z → 직전 별점 복구
- [ ] 드래그 리오더 → 순서 변경 (단일 + 다중)
- [ ] 화살표 키 네비게이션 → 선택 이동
- [ ] 프리뷰 확대 (Enter) → 고해상도
- [ ] 즐겨찾기 추가/제거
- [ ] 최근 폴더 네비게이션
- [ ] 품질 분석 실행 → 배지 표시
- [ ] 씬 분류 실행 → 태그
- [ ] 얼굴 그룹핑 실행 → 그룹
- [ ] 배치 리네임 → 파일명 변경 + Undo
- [ ] 내보내기 → JPG/RAW 폴더 생성

모두 OK면 완료. 하나라도 깨지면 해당 도메인 태스크 커밋을 `git revert`.

- [ ] **Step 6: 최종 커밋 (정리 있을 시)**

Step 2에서 누락된 함수 이동이나 코드 정리가 있었다면:

```bash
cd /Users/potokan/PhotoRawManager && git add PhotoRawManager/Models/PhotoStore*.swift
git commit -m "$(cat <<'EOF'
refactor(PhotoStore): 분할 마무리 및 남은 함수 정리

- 코어 PhotoStore.swift: class declaration + @Published + filteredPhotos + init + sortPhotos + invalidate*
- 전체 3694줄 → 코어 ~1100줄 (분할율 70%)

PhotoStore 분할 9/9 완료.

Co-Authored-By: Claude Opus 4.6 <noreply@anthropic.com>
EOF
)"
```

정리할 게 없으면 이 커밋은 생략.

- [ ] **Step 7: 성능 체감 테스트 (선택)**

분할 전후 성능 비교. 대형 폴더(1000+ 장) 열어서:
- 썸네일 그리드 스크롤 부드러움
- 선택 이동 반응성
- 필터 변경 지연

분할 자체는 기능적으로 동등해야 하므로 성능 변화 없어야 정상. 만약 느려졌다면 어디선가 뷰 무효화가 과도해졌을 것 — `Self._printChanges()` 나 Instruments로 추적.

---

## 롤백 절차

### 태스크 1개 실패
해당 태스크 커밋만 되돌리기:
```bash
git revert <task-commit-hash>
```

### 중간에 여러 태스크 실패, 분할 작업 포기
`d24f1af` (분할 시작 직전) 로 완전 되돌리기:
```bash
git reset --hard d24f1af
```
(이미 origin에 push된 상태면 `--force` 필요. 주의.)

### 특정 파일만 원복
```bash
git checkout d24f1af -- PhotoRawManager/Models/PhotoStore.swift
```

---

## Self-Review 체크

**1. Spec coverage**
- ✅ 115 @Published → 저장 속성은 코어 유지 (언어 제약)
- ✅ 3694줄 → 코어 1100줄 + 9개 파일로 분산
- ✅ 동작 변경 0 → 모든 태스크가 순수 이동
- ✅ 각 태스크 커밋 단위 = 롤백 가능

**2. Placeholder scan**
- 각 태스크가 "해당 함수 본문을 그대로 복사"라고 되어 있는데, 이건 플레이스홀더 아니라 명시적 지시. 본문 내용은 이미 파일에 있으므로 중복 인용 불필요.
- 태스크별 예상 줄수는 근사치임을 명시.
- pbxproj 편집은 "기존 PhotoStore.swift 항목을 찾아 같은 형식으로 추가"로 구체화.

**3. Type consistency**
- 모든 파일이 `extension PhotoStore { }` 일관된 패턴.
- `internal` / `fileprivate` / `private` 구분 기준이 각 태스크에 명시됨.
- `PBXFileReference` / `PBXBuildFile` ID 스킴 일관 (PS20001~PS20016).

**4. 발견된 리스크**
- `didSet` 블록이 호출하는 private 함수의 접근 수준 변경은 태스크별로 명시됨.
- 대형 태스크(Task 8 Analysis)는 중간 빌드 권장 명시됨.
- 변수 연결 오류(접근 수준)에 대한 실패 시 fix 지침 제공.

---

## 체크리스트

- [ ] Task 0: 사전 확인
- [ ] Task 1: Collections.swift
- [ ] Task 2: UI.swift
- [ ] Task 3: Exif.swift
- [ ] Task 4: Rating.swift
- [ ] Task 5: Selection.swift
- [ ] Task 6: Folder.swift
- [ ] Task 7: Move.swift
- [ ] Task 8: Analysis.swift
- [ ] Task 9: 정리 및 최종 검증
