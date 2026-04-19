# PickShot v8.6.3 심층 분석 보고서
*(2026-04-20 작성 · 새벽 세션 종료 시점)*

---

## ✅ v8.6.3 에 포함된 작업

### 성능 / 안정성
- **적응형 3층 메모리 가드** (MemoryGuardService) — RAM 크기에 동적, OS memorypressure 연동
- **스트리밍 + 병렬 하위폴더 스캔** (FileMatchingService.scanAndMatchStreaming) — 3대 카메라 시나리오 ~3-5배 체감
- **CacheSweeper 스트리밍 대응** — photosVersion 감시, tier 기반 range 확대
- **회전 기능 serial queue 직렬화** — 빠른 연속 클릭 버그 해결

### UX 개선
- **러버밴드(마우스 드래그) 선택** — 최대 단점이었던 이슈 해결
- **일괄 회전 (우클릭 90°/180°/270°)** — JPG 무손실 EXIF + RAW XMP 사이드카 (Lightroom/C1 호환)
- **회전 버튼 스프링 애니메이션**
- **Camera Raw 에서 열기** — Bundle ID 기반 Photoshop 탐색

### 기반 인프라
- `PhotoStore+Rotation.swift` 신규
- `RotationService.swift` 신규
- `MarqueeSelectionBackground` 신규
- `PreviewImageCache.trimOldest(ratio:)` 신규
- `CacheSweeper.previewRangeAroundSelection` tier 기반

### 배포
- GitHub 릴리즈 v8.6.1 DMG 교체 완료 (33.7MB, 공증 + 스테이플)

---

## 📊 코드베이스 현황 스캔

### 규모
- Views: **38,000 줄**  (46 files)
- Services: **24,000 줄**  (40+ files)
- Models: **8,500 줄**
- **합계: ~70,000 줄**

### 복잡도 Hotspot Top 5
1. `ThumbnailGridView.swift` — **4,165줄** ⚠️ (리팩토링 필요)
2. `PhotoPreviewView.swift` — **3,948줄** ⚠️ (@State 54개)
3. `ContentView+FolderBrowser.swift` — 1,567줄
4. `KeyEventHandling.swift` — 1,385줄
5. `PhotoStore.swift` — 1,212줄

### @State 과다 View Top 5
1. PhotoPreviewView (54) — PreviewViewState 분리 더 필요
2. MetadataEditorView (27)
3. BatchProcessView (20)
4. ThumbnailGridView (19)
5. ExportView (18)

---

## 🔴 크리티컬 이슈 (남은 것)

### 1. 동시성 (Swift 6 마이그레이션 대비)
- `ClaudeVisionService.swift:599` — 병렬 클로저에서 var capture race
- `VideoPlayerManager.swift:610` — @Sendable closure self capture
- `PhotoPreviewView.swift:1919, 1939` — actor-isolated 접근 경고

**영향**: 현재 동작엔 영향 없으나 Swift 6 로 이동 시 에러. 단발성 작업으로 정리 가능.

### 2. macOS 14+ deprecated (40곳)
- `onChange(of:perform:)` — 단순 자동 변환 가능 (스크립트로 한번에)
- `usesCPUOnly` (Vision) — 2곳 (이미 GPU 기본 동작이라 제거만 하면 됨)
- `kUTTypePNG/JPEG` (`CropView.swift:536`) — UTType 으로 대체

**영향**: 현재 동작엔 영향 없음. 경고 소음만.

### 3. 무시되는 리턴값
- `FileCopyService.swift:134-135`, `MemoryCardBackupService.swift:362-364` — `fcntl` 실패 감지 못함 (파일 플래그)
- 이미 수정: `ArchiveStream.process` 는 `_ =` 추가됨 / `draggingSession` 의 weak self 제거 / 죽은 ProgressView HStack 으로 감쌈

---

## 🔍 기능별 동작 검증 (로그 기반)

### ✅ 정상 동작 확인
- 썸네일 캐시: `thumbnail cache HIT` 연발 → 정상
- 디스크 캐시: **2400 파일 / 719MB** 저장 중 → 정상
- SWEEP: thumbs 758장 생성 완료, previews 는 "이미 캐시됨" 스킵 → 정상
- 회전 파이프라인: 파일 수정 + XMP 사이드카 + override + 통지 전파 → 정상
- ARW 세로 사진 방향 보정: CIImage.oriented 경로 정상
- 러버밴드 선택: PreferenceKey + 라이브 하이라이트 정상

### 🟡 확인 필요 (다음 세션)
- **스크롤바 + 창 리사이즈 겹침** — macOS NSScrollView 구조 이슈. ContentView 상위에서 trailing padding 적용 필요
- **필름스트립 스크롤 속도** — 방향키 long press 시 CPU % 확인 필요
- **6000장 스트리밍 실측** — 아직 실제 큰 폴더로 검증 못 함

---

## 🌐 GitHub 기반 업그레이드 아이디어

### 활용 가치 높은 오픈소스
1. **darktable (`/darktable/darktable`)** — RAW 현상 엔진 참조
   - 개선 포인트: HSL 슬라이더, Tone Equalizer, 노이즈 감소 (denoise non-local)
   - 라이선스: GPL-3 — 직접 포함 불가, 알고리즘 참고만

2. **Adobe DNG SDK** — DNG/RAW 메타데이터 처리 (사용자 로컬 설치됨)
   - XMP 사이드카 write 시 Adobe 표준 100% 호환 가능

3. **`apple/ml-stable-diffusion`** 의 Core ML 변환 패턴 — CLIP 로컬화 시 참조

4. **`mlfoundations/open_clip`** — 오픈 CLIP 모델 (MIT)
   - Core ML 로 변환 후 로컬 "부케 들고 있는 사진" 같은 의미 검색 가능
   - 모델 크기: 150-300MB

5. **`kean/Nuke`** — 이미지 로딩 파이프라인 (MIT)
   - 우리 ThumbnailLoader 대체 가능. 캐시 전략 / HTTP / WebP 등 풍부
   - 단, Nuke 는 URL 기반이라 로컬 파일 전용 우리와는 부분 대체

6. **`onevcat/Kingfisher`** — 이미지 로딩 (MIT)
   - SwiftUI 통합 잘됨. 다만 우리는 로컬 RAW 디코딩이 핵심이라 제한적

### UX 참조
- **`exif-js/exifr`** — JavaScript 기반이지만 EXIF 파싱 로직 참고
- **`libraw/libraw`** — Camera RAW 포맷 레퍼런스 (LGPL — 조심)
- **Capture One** 의 "Color Editor" — HSL 세분화 UX
- **Lightroom Classic** 의 Culling 단축키 (P/X/U flagging)

### 추천 우선순위
1. **Apple CLIP 로컬 의미 검색** — v8.7 에서 가장 큰 차별화 요소
2. **darktable 의 HSL/Tone curve 알고리즘** — DevelopPipeline 강화
3. **libraw 평가** — Sony ARW 변형 디코딩 안정성 (연구 후 결정)

---

## 🎯 차기 로드맵 (합의된 순서)

1. **(배포 완료)** v8.6.3 — 본 보고서 시점의 모든 변경
2. **차주**: Lite / Pro IAP 분리 (단일 앱 + 일회성 Pro unlock $39)
3. **v8.7 (2-1)**: 얼굴 그룹 + 이름 태깅 + 인물 필터
4. **v8.8 (2-2)**: CLIP 로컬 의미 검색
5. **지속적**: Deprecated API 일괄 정리, 동시성 경고 정리

---

## 📋 즉시 해결 가능한 정리 항목 (한 번에 스크립트화 가능)

```bash
# 1. onChange 변환 (40곳)
grep -rln "onChange(of: [^,]*, perform:" PhotoRawManager/ --include="*.swift"
# → `.onChange(of: x) { newValue in ... }` 로 변환

# 2. 미사용 immutable (14곳 확인됨, 일부 정리됨)
# Models/PhotoStore+Analysis.swift:274 ✅ 정리됨
# Views/PhotoPreviewView.swift:2112-2113 ✅ 정리됨
# 나머지 12곳 — 각각 확인 후 `_ =` 처리

# 3. usesCPUOnly 제거 (2곳)
# Services/AdvancedClassificationService.swift:77
# Models/PhotoStore.swift:1007, 1013
```

---

## 💡 철학 유지 확인

- ✅ **코드 단순하게** — 러버밴드 / 회전 서비스 모두 단일 책임
- ✅ **에이전트 병렬** — 세션 내에서 작업 분할했음
- ✅ **한국어 소통** — 유지
- ✅ **세상에서 제일 빠른 뷰잉** — 스트리밍 로드 + 적응형 메모리로 강화

---

*끝.*
