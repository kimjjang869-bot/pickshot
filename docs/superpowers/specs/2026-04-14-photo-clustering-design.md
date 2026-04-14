# 유사 컷 클러스터링 — 설계 문서

- 작성일: 2026-04-14
- 대상 버전: v8.1 예정
- 관련 기존 파일: `Services/AISimilarityService.swift`, `Services/FolderWatcherService.swift`, `Views/ThumbnailGridView.swift`

## 목표

연사/브라케팅/비슷한 포즈로 찍힌 사진을 자동으로 묶어 썸네일 그리드를 정돈하고, 컬링 속도를 높인다. Adobe Bridge 스택 방식 + AI 베스트 자동 선정.

## 비목표

- 얼굴 기반 클러스터링 (`FaceGroupingService`에 이미 존재 — 중복)
- 완전 자동 "베스트 1장만 보이고 나머지 숨김" 모드 (작가 신뢰 문제 — YAGNI)
- 클라우드 동기화 (별도 기능)
- 그룹 단위 일괄 보정 (별도 기능)

## 사용자 시나리오

**시나리오 1 — 결혼식 입장 장면 (연사)**
1. 10초 동안 10장 연사로 찍음
2. "유사 컷 묶기" 버튼 → 10장이 한 그룹으로 묶임
3. 그룹 대표는 AI 품질 점수 1등 (초점 선명, 눈 뜬 사진)
4. 썸네일 그리드에서 대표 1장만 보임, 뱃지 `[10] ✨`
5. 뱃지 클릭 → 10장 인라인 펼침 → 빠르게 비교 후 1장 별점 부여

**시나리오 2 — 포즈 바꿔가며 촬영 (세션 포토)**
1. 같은 장소에서 포즈 5번 바꿔 30장 촬영 (각 포즈 간 5~10초)
2. 클러스터링 → 6~7개 그룹 자동 생성 (pHash 비슷한 것끼리)
3. 풍경/단독 사진 (1장짜리)은 그룹 안 만들어짐

**시나리오 3 — 캐시 활용 (재방문)**
1. 이미 클러스터링 돌린 폴더 재오픈
2. `.pickshot_clusters.json` 캐시에서 즉시 로드 (< 100ms)
3. 새 사진 10장 추가 → FolderWatcher 감지 → 툴바 "업데이트 필요" 배지
4. 사용자 클릭 → 증분 재계산 (추가된 사진만)

## 아키텍처

### 레이어 구성

```
┌─────────────────────────────────────────────┐
│ UI Layer                                    │
│  ThumbnailGridView (그룹 뱃지 + 인라인 확장) │
│  ContentView+Toolbar (클러스터 버튼)        │
│  SettingsView (파라미터)                    │
└─────────────────────────────────────────────┘
                  ↓
┌─────────────────────────────────────────────┐
│ Store Layer                                 │
│  PhotoStore (clusters, clusteringProgress) │
└─────────────────────────────────────────────┘
                  ↓
┌─────────────────────────────────────────────┐
│ Service Layer (신규)                        │
│  PhotoClusteringService (알고리즘)          │
│  ClusterCacheService (캐시 I/O)             │
└─────────────────────────────────────────────┘
                  ↓
┌─────────────────────────────────────────────┐
│ 기존 Layer (재사용)                         │
│  AISimilarityService.computePHash          │
│  ImageAnalysisService (품질 점수)           │
│  FolderWatcherService (파일 변경 감지)      │
└─────────────────────────────────────────────┘
```

### 신규 타입

**런타임 표현 (메모리):**
```swift
struct PhotoCluster: Identifiable {
    let id: UUID
    var memberIDs: [PhotoItem.ID]       // 그룹에 속한 사진 ID들 (시간순)
    var representativeID: PhotoItem.ID  // 대표 썸네일
    var timeRange: ClosedRange<Date>
    var avgPHashSimilarity: Double
    var isExpanded: Bool = false        // UI 상태
}
```

**캐시 표현 (디스크, Codable):**
```swift
struct ClusterCacheEntry: Codable {
    var memberFileNames: [String]       // PhotoItem.id는 UUID 런타임값이라 저장 불가
    var representativeFileName: String
    var timeRangeStart: Date
    var timeRangeEnd: Date
    var avgPHashSimilarity: Double
}
```

로드 시 `ClusterCacheService`가 `PhotoStore.photos`에서 `fileName` 매칭하여 `PhotoCluster`로 변환.

struct ClusteringParameters: Codable {
    var burstIntervalSec: Double = 2.0        // 연사 인식 간격
    var groupMaxGapSec: Double = 10.0         // 같은 그룹 최대 간격
    var pHashThreshold: Double = 0.88         // pHash 유사도 임계
    var minGroupSize: Int = 2                  // 최소 그룹 크기
    var autoOnFolderOpen: Bool = false        // 폴더 열 때 자동 실행
}

struct ClusterCacheFile: Codable {
    let version: Int            // 현재 1
    let generatedAt: Date
    let fileHash: String        // 파일명+수정일 SHA1
    let clusters: [PhotoCluster]
}
```

### 기존 타입 변경

**PhotoStore.swift 추가:**
```swift
@Published var clusters: [PhotoCluster] = []
@Published var clusteringInProgress: Bool = false
@Published var clusteringProgress: Double = 0.0
@Published var clusterCacheDirty: Bool = false  // 파일 변경 감지 후
@Published var expandAllGroups: Bool = false

func computeClusters() async          // 사용자 버튼 클릭
func loadClustersFromCache() -> Bool  // 폴더 열 때
func toggleGroupExpansion(_ id: UUID)
func toggleExpandAll()
func invalidateClusters()              // 파일 변경 시
```

## 알고리즘

### 2단계 클러스터링

```
Phase 1 — 시간 기반 예비 그룹
  1. photos를 EXIF DateTimeOriginal 순으로 정렬 (없으면 fileModDate)
  2. 순회하며 인접 사진 간격 측정:
     - ≤ burstIntervalSec (2초): 같은 "버스트"로 묶음
     - ≤ groupMaxGapSec (10초): 같은 "장면 후보"로 묶음
     - 초과: 새 그룹 시작
  3. 결과: [[PhotoItem]] — 시간 기반 후보 그룹 리스트

Phase 2 — pHash 정제
  for group in 후보 그룹:
    if group.count < minGroupSize: continue (버림)
    
    // 대표 pHash 계산 (그룹 중 품질 점수 1등)
    representative = group.max(by: qualityScore)
    repHash = AISimilarityService.computePHash(representative)
    
    // 대표와 유사도 높은 것만 최종 그룹에 포함
    finalMembers = group.filter { member in
      memberHash = computePHash(member)
      similarity = hammingSimilarity(repHash, memberHash)
      return similarity >= pHashThreshold
    }
    
    // 제외된 사진은 다음 그룹 후보로 재분배 (재귀)
    // 최종 그룹 크기가 minGroupSize 미만이면 해체 (단일 사진)
    
    if finalMembers.count >= minGroupSize:
      yield PhotoCluster(
        members: finalMembers,
        representative: representative,
        timeRange: firstDate...lastDate,
        avgPHashSimilarity: avg
      )
```

### 병렬화

- Phase 2의 pHash 계산을 `concurrentPerform(iterations:)` 로 병렬화
- 배치 크기 100장 단위, 메모리 압박 시 축소
- 진행률 콜백: 100장마다 `DispatchQueue.main.async { progress = ... }`

### 캐시 무효화 감지

```swift
func computeFolderHash(photos: [PhotoItem]) -> String {
    let sorted = photos.sorted { $0.fileName < $1.fileName }
    let input = sorted.map { "\($0.fileName):\($0.fileModDate.timeIntervalSince1970)" }
        .joined(separator: "\n")
    return SHA1(input)
}

// 캐시 로드 시:
if cache.fileHash == computeFolderHash(currentPhotos) {
    // 캐시 유효
} else {
    clusterCacheDirty = true  // 툴바에 "업데이트 필요" 표시
}
```

## UI 설계

### 썸네일 그리드 확장

**일반 셀:**
- 변경 없음

**그룹 대표 셀:**
- 오른쪽 위 뱃지: `[12] ✨` (그룹 크기 + 대표 마커)
- 뱃지 클릭: 해당 그룹만 펼침 토글
- 대표 썸네일은 AI 품질 점수 1등

**그룹 멤버 셀 (펼친 상태):**
- 셀 테두리 파란색 (그룹 소속 표시)
- 왼쪽 위 `2` (순서) 작은 라벨

**인라인 확장 레이아웃:**
```
Row N:
  [단일]  [그룹대표]  [단일]  [단일]
           [12]✨
  
Row N+0.5 (펼친 상태 추가 행):
  ┌──────────────────────────────────┐
  │ [멤버2][멤버3][멤버4]...[멤버12] │
  └──────────────────────────────────┘
  
Row N+1:
  [단일]  [단일]  [그룹대표]  [단일]
                   [5]✨
```

### 툴바

**클러스터 없을 때:**
```
[유사 컷 묶기]  ← 버튼
```

**클러스터 계산 중:**
```
[🔄 유사 컷 묶는 중... 42% (512/1234장)]  [취소]
```

**클러스터 있을 때:**
```
[85개 그룹 · 523장 묶임 (31%↓)]  [모두 펼치기]
```

**캐시 무효 시:**
```
[85개 그룹]  [⚠️ 업데이트 필요]
```

### 키보드 단축키

```
→              다음 그룹 대표로 이동 (그룹 단위 스킵)
Shift + →      그룹 내 다음 사진으로 이동
Space          현재 그룹 펼치기/접기
Cmd+Shift+G    전체 그룹 펼치기/접기 토글
Cmd+G          유사 컷 묶기 (재계산)
```

### Settings

```
┌─ 유사 컷 클러스터링 ────────────────────────┐
│                                              │
│ ☐ 폴더 열 때 자동 클러스터링                 │
│                                              │
│ 연사 간격:       [2]초                       │
│ 그룹 최대 간격:  [10]초                      │
│ pHash 임계:     [0.88]  (0.5 관대 - 0.95 엄격)│
│ 최소 그룹 크기:  [2]장                       │
│                                              │
│ ☐ 캐시 파일 숨김 (.pickshot_clusters.json)  │
│                                              │
│  [기본값으로]              [테스트 실행]      │
└──────────────────────────────────────────────┘
```

## 에러 처리

| 상황 | 처리 |
|------|------|
| EXIF 촬영시간 없음 | `fileModDate`로 폴백 |
| pHash 계산 실패 (손상 이미지) | 해당 사진 단일 그룹 처리, 로그 기록 |
| 캐시 파일 손상 (JSON 파싱 실패) | 무시하고 처음부터 재계산 |
| 캐시 version 불일치 | 무시하고 재계산 |
| 클러스터링 중 폴더 닫기 | `DispatchWorkItem.cancel()` 호출, 부분 결과 버림 |
| 메모리 압박 (경고) | 배치 크기 축소 (100 → 50), 재개 |
| 품질 점수 데이터 없음 (분석 전) | 첫 번째 사진을 대표로 (fallback) |

## 캐시 파일 포맷

경로: `{folderURL}/.pickshot_clusters.json`

```json
{
  "version": 1,
  "generatedAt": "2026-04-14T10:30:00Z",
  "fileHash": "sha1_abc123...",
  "clusters": [
    {
      "memberFileNames": ["R5_0042.CR3", "R5_0043.CR3", "R5_0044.CR3"],
      "representativeFileName": "R5_0042.CR3",
      "timeRangeStart": "2026-04-14T10:30:15Z",
      "timeRangeEnd": "2026-04-14T10:30:17Z",
      "avgPHashSimilarity": 0.92
    }
  ]
}
```

`PhotoItem.id`는 폴더 로드마다 새로 생성되는 UUID라 저장 불가 → 파일명으로 저장하고 로드 시 `PhotoStore.photos`에서 매칭하여 현재 id로 해석.

## 테스트 전략

### 단위 테스트

**PhotoClusteringServiceTests**
- `time_groupsConsecutiveShots`: 0.5초 간격 연사 10장 → 1그룹
- `time_splitsOnLongGap`: 15초 간격 사진 → 2그룹
- `phash_filtersOutDifferentScene`: 시간 근접이지만 장면 전환 → 다른 그룹
- `minSize_dissolvesSingletons`: 1장 짜리 예비 그룹 → 해체
- `representative_picksBestQualityScore`: 그룹 내 품질 점수 1등이 대표
- `representative_fallbackWhenNoQualityScore`: 품질 분석 전 → 첫 사진이 대표
- `exifMissing_usesFileModDate`: EXIF 없는 파일 → 수정일 사용

**ClusterCacheServiceTests**
- 저장/로드 라운드트립
- 파일 해시 변경 감지
- 손상된 JSON → nil 리턴
- version 불일치 → nil 리턴

### 통합 테스트

- 30장 테스트 이미지 (5그룹 × 6장 + 단일 5장) → 정확히 5그룹 + 단일 5장 생성
- 1장 삭제 후 `clusterCacheDirty == true`
- 1장 추가 후 재계산 → 새 그룹 or 기존 그룹 확장

### 수동 테스트

- [ ] 실제 결혼식 사진 1000장 폴더로 정확도 확인
- [ ] 브라케팅 HDR 3장 → 같은 그룹으로 묶임
- [ ] 풍경+인물 혼합 폴더 → 합리적 그룹핑
- [ ] 그룹 펼친 상태 스크롤 60fps 유지
- [ ] 캐시 저장/재로드 <100ms

## 성능 목표

- 1,000장: 15초 이내 (pHash 병렬화)
- 5,000장: 1분 이내
- 10,000장: 2분 이내 (메모리 안전)
- 캐시 히트 시: < 100ms
- 그룹 펼침 애니메이션: 60fps
- 메모리 사용: 클러스터링 피크 시 +200MB 이내

## 신규/수정 파일

### 신규
1. `Services/PhotoClusteringService.swift` — 알고리즘
2. `Services/ClusterCacheService.swift` — 캐시 I/O
3. `Models/PhotoCluster.swift` — 데이터 모델
4. (테스트) `PhotoClusteringServiceTests.swift`, `ClusterCacheServiceTests.swift`

### 수정
- `Models/PhotoStore.swift` — clusters/progress/actions 추가
- `Views/ThumbnailGridView.swift` — 그룹 뱃지, 인라인 확장 렌더링 (`LazyVGrid` 섹션)
- `Views/ContentView+Toolbar.swift` — 클러스터 버튼, 진행률 표시
- `Services/FolderWatcherService.swift` — 파일 변경 시 `onClusterCacheInvalidated` 콜백
- `Views/SettingsView.swift` — 클러스터링 섹션
- `PhotoRawManagerApp.swift` — 키보드 단축키 (Cmd+Shift+G, Cmd+G)

## 기존 코드 개선

- `AISimilarityService.computePHash`: 호출부가 늘어나므로 결과 캐싱 검토 (현재는 매번 디코딩). 파일명+수정일 → UInt64 해시 LRU 캐시 (별도 스펙)
- `ThumbnailGridView.swift`: 이미 긴 파일 (플랜 요약 기준 3000+줄) — 그리드 셀을 `ClusterGridCell`, `SingleGridCell` 로 분리 리팩터링

## 릴리즈 계획

- **M1 (1주)**: PhotoClusteringService + 단위 테스트
- **M2 (3일)**: ClusterCacheService + 통합 테스트
- **M3 (1주)**: ThumbnailGridView 그룹 UI + 툴바
- **M4 (3일)**: Settings + 키보드 단축키
- **M5 (3일)**: 수동 테스트 + 최적화
- **v8.1 릴리즈**: 총 ~3주
