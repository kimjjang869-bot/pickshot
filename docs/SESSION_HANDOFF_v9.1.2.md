# PickShot v9.1.2 — 세션 핸드오프

다음 세션 시작할 때 이 파일 전체를 붙여넣으세요.

---

## 프로젝트
- **PickShot** macOS RAW 사진 컬링 앱 (Swift/SwiftUI + Metal + Vision)
- 12년차 커머셜 포토그래퍼 본인이 사용. **세상에서 제일 빠른 뷰잉 + 쉬운 UI** 가 모토
- 한국어로 대화. 사용자는 코드 단순함 선호 (복잡 = 메모리 문제)
- GitHub: https://github.com/kimjjang869-bot/pickshot
- Repo: `/Users/potokan/PhotoRawManager` (메인) / 작업 worktree: `.claude/worktrees/stupefied-golick-053cd8`
- 현재 브랜치: `feature/frv-gap-close-v9.1`
- 배포된 DMG: `backups/PickShot-v9.0.2-build40-hotfix-20260501-2204.dmg` (notarized + stapled)

## 백업 태그 (롤백 가능)
```
backup/v9.0.2-build41-stable-20260430-2310    # v9.1 작업 시작 전
backup/v9.1-pre-mode-merge-20260501-1951      # 4토글 → 1picker 통합 전
```
롤백: `cd /Users/potokan/PhotoRawManager && git reset --hard <tag>`

## 빌드/실행 (디버그 모드 — 항상 stderr 캡처)
```bash
cd /Users/potokan/PhotoRawManager
xcodebuild -project PhotoRawManager.xcodeproj -scheme PhotoRawManager \
  -configuration Debug ARCHS=arm64 ONLY_ACTIVE_ARCH=YES build 2>&1 | grep -E "error:" | head
pkill -9 -f "PickShot" 2>/dev/null; sleep 1
/Users/potokan/Library/Developer/Xcode/DerivedData/PhotoRawManager-dahhmrojpurourexepfejdgkxrbw/Build/Products/Debug/PickShot.app/Contents/MacOS/PickShot > /tmp/pickshot_debug.log 2>&1 &
```

로그 분석:
```bash
tail -c 100000 /tmp/pickshot_debug.log | iconv -f UTF-8 -t UTF-8//IGNORE | grep "STALL" | tail
```

## v9.1.2 적용된 변경 (성능/UX)

### 1. 4토글 → 1 segmented picker
- **PhotoStore.swift** `PerformanceProfile` enum (`.standard / .fastCull / .prewarm`)
- 기존 fastCullingMode/aggressiveCache/SuperCullMode/autoInitialPreview 동시 동기화
- 툴바: `PerformanceProfilePicker` (CacheProgressGauge.swift) + 라이브 게이지
- 설정: 동일 picker (PerformanceOptimizeTab.swift)
- `autoInitialPreview` 자동 ON 영구 차단 (phase3 무한 발사 hang 원인이었음)

### 2. 폴더 트리 다중 선택 + 일괄 열기
- **ContentView+FolderBrowser.swift**
- Cmd+클릭/Shift+클릭 다중 선택 (multiFolderSelection: Set<URL>)
- 액션 바: "[일괄 열기] N개 선택"
- **PhotoStore+Folder.swift** `loadFoldersAggregated(_ urls:)` — 비재귀 스캔 합쳐서 표시

### 3. 스캔 진행률 (X/Y 폴더)
- **FileMatchingService.swift** `scanAndMatchStreaming` 에 `onProgress` 콜백
- **PhotoStore+Folder.swift** 재귀 스캔 시 `loadingProgress = done/total` 갱신

### 4. 별점/SP/컬러 폴더별 분산 저장 (하위폴더 모드 데이터 손실 수정)
- **PhotoStore+Rating.swift** `performSaveRatings`
  - 사진별 *실제 소속 폴더* 별로 그룹화 → UserDefaults `folderSelections` 통합 dict + 폴더별 `.pickshot_selection.json`
  - inflight 가드 (`Self.saveInflight`)
  - debounce 400ms → 2000ms
  - isFastNavigation 시 더 미룸
  - XMP / JSON diff (변경된 것만 쓰기)
- `applySavedRatings`
  - 폴더별 dict 1회 일괄 로드 (`perFolderCache`)
  - `_suppressDidSet=true` 로 photos[i].rating 변경 시 didSet 폭주 방지
  - 재귀 모드는 `flushRecursiveScanUI(final: true)` 1회만 호출 (이전 매 batch 호출 → 40초 STALL)

### 5. 자동 캐시 reset (latency-based)
- **KeyEventHandling.swift** — 항상 nav interval 샘플링 (30개 링버퍼)
- 최근 15개 평균 > 130ms + 5초 쿨다운 → `NavigationPerformanceMonitor.forceFlushAllCaches()`
- 로그: `[AUTO-RESET] avg XXXms > 130ms — cache flush`

### 6. 버스트 prefetch throttle
- **PhotoPreviewView.swift** `prefetchEmbeddedNeighbors`
  - `store.isFastNavigation` 시 250ms hard throttle
  - `lastBurstThrottleTime` static
- 이전: 매 키마다 BURST-START 발사 → 14초 STALL

### 7. RAW Stage 2 NO-UPGRADE 캐시
- **PreviewPipeline.swift** `runRAW`
  - `Self.noStage2Upgrade: Set<URL>` — Stage 2 결과가 Stage 1 ≤ 1.05× 면 마킹
  - 다음 nav 시 Stage 2 자체 SKIP → main 재렌더 STALL 회피
- 로그: `[LD] RAW-S2 NO-UPGRADE filename`

### 8. AsyncThumbnailView 빠른 스크롤 SKIP
- **ThumbnailGridView.swift** `AsyncThumbnailView.loadThumbnail`
  - 캐시 미스 + (`PhotoStore.navigationBusy` || `Self.detectRapidScroll()`) → 즉시 SKIP
  - `detectRapidScroll`: 200ms 윈도우 8셀 이상 onAppear 감지
  - 0.3초 후 자동 재시도

### 9. CacheSweeper 키 이동 시 즉시 중단
- **KeyEventHandling.swift** — `store.isKeyRepeat = true` 즉시 `CacheSweeper.shared.notifyActivity()` 호출

### 10. 필름스트립 풀스크린 패턴 (라이트룸식 슬롯 고정)
- **FilmstripView.swift** `windowedFilmstrip`
  - LazyHStack 17000장 ForEach → 슬롯 고정 (visibleW/cellW, 홀수)
  - 중앙 슬롯에 항상 selectedPhoto → 파란 보더 화면 정중앙 고정 (안 움직임)
  - 키 이동 시 각 슬롯 사진만 swap (보더 자리 그대로)
  - 시각 스크롤바 (하단 8pt) — 드래그로 selection 변경
  - HStack `.frame(maxWidth: visibleW).clipped()` + 외곽 `.clipped()` (사이드바 침범 차단)
  - **현재 상태:** 슬롯 swap 동작. 사용자는 추가 피드백 줄 수 있음

### 11. 피드백 게시판 (사이트)
- **website/feedback.html** — 진짜 게시판 UI (탭/검색/글쓰기/상세/댓글/삭제)
- **docs/board-worker.js** — Cloudflare Worker (KV 백엔드, 익명 가능)
- **상태:** Worker 미배포 — `BOARD_API` 빈 string 상태. 사용자가 Cloudflare 직접 배포 후 URL 입력 필요
- gh-pages 브랜치에 commit `a79242d` 로 배포됨

### 12. v9.0.2 build 40 핫픽스 DMG
- 버전 번호 안 바꾸고 빌드 → 서명 → 공증 → 스테이플 완료
- `backups/PickShot-v9.0.2-build40-hotfix-20260501-2204.dmg`

## 유저 시스템 / 환경
- Mac16,9 (M4 Max, 64GB)
- Apple Development cert: `kimjjang869@gmail.com (28K55WTK4S)` — 일반 빌드
- Developer ID Application: `Kwangho Kim (322DLHS5T8)` — 배포용
- 공증 자격증명: app password `tspp-ubpl-utto-uixs`
- 시크릿: `Secrets.xcconfig` (Google OAuth client/secret) — git ignored

## 현재 미해결 / 진행 중
1. **필름스트립 슬롯 패턴 검증 중** — 마지막 사용자 피드백 "재실행" 후 코멘트 없음. 다음 세션에서 실제 동작 확인 필요
2. **18초/14초 STALL** — 대부분 fix 됨 (saveRatings inflight + applySavedRatings final-only + prefetch throttle). 추가 검증 필요
3. **메모리 누수 (RAM 5GB+ 누적)** — MemGuard Layer 임계값 더 낮추는 것 검토 필요
4. **board-worker.js 배포** — 사용자 Cloudflare 작업 대기

## 주요 파일 위치
```
PhotoRawManager/
├── Models/
│   ├── PhotoStore.swift              # PerformanceProfile + applyPerformanceProfile
│   ├── PhotoStore+Rating.swift       # 폴더별 분산 저장/복원
│   ├── PhotoStore+Folder.swift       # loadFoldersAggregated, 재귀 스캔 진행률
│   └── PhotoStore+Selection.swift    # markNavigationBurstIfNeeded
├── Services/
│   ├── SuperCullMode.swift           # UserDefaults 토글
│   ├── NavigationPerformanceMonitor.swift  # forceFlushAllCaches
│   ├── CacheSweeper.swift            # notifyActivity
│   └── FileMatchingService.swift     # scanAndMatchStreaming + onProgress
├── Views/
│   ├── PhotoPreviewView.swift        # prefetchEmbeddedNeighbors throttle, loadHiResForZoom guard
│   ├── PreviewPipeline.swift         # noStage2Upgrade
│   ├── ThumbnailGridView.swift       # AsyncThumbnailView (필름스트립 + 그리드 공유)
│   ├── FilmstripView.swift           # windowedFilmstrip (슬롯 고정 라이트룸식)
│   ├── KeyEventHandling.swift        # AUTO-RESET, navIntervalSamples
│   ├── PreviewLoadingPolicy.swift    # shouldAutoLoadHiRes (SuperCullMode)
│   ├── CacheProgressGauge.swift      # PerformanceProfilePicker
│   └── Settings/PerformanceOptimizeTab.swift
website/
├── feedback.html                     # 게시판 UI
└── ...
docs/
├── board-worker.js                   # Cloudflare Worker
└── SESSION_HANDOFF_v9.1.2.md         # 이 파일
.github/ISSUE_TEMPLATE/                # 버그/기능 템플릿
```

## 사용자가 가장 자주 요청하는 작업 패턴
- 코드 변경 → `xcodebuild build` → 에러만 grep → 재실행 → 사용자 피드백
- 로그 분석 (`/tmp/pickshot_debug.log` STALL grep)
- "로그체크" → 로그 분석 후 STALL 원인 진단 + 수정
- "재실행" → pkill + 새 프로세스
- "롤백" → git tag 로 복원
- "공증받구" → Release 빌드 + sign + dmg + notarize + staple

## 다음 세션 시작 시 실행할 명령
```bash
cd /Users/potokan/PhotoRawManager
git status --short
tail -c 50000 /tmp/pickshot_debug.log | iconv -f UTF-8 -t UTF-8//IGNORE | grep -E "STALL|AUTO-RESET|BACKUP" | tail -20
```
