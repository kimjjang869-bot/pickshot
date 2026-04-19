# PickShot 심층 분석 보고서
*(2026-04-20 새벽 작업 완료분 + 다음 단계)*

## 오늘밤 적용 완료 (v8.6.3 예정)

### ✅ #3 적응형 메모리 (Adaptive 3-Tier Memory Guard)
- 하드코딩 6GB 상한 **제거**. SystemSpec.ramGB 기반 동적 목표치.
- **Layer 1 (soft target)** = min(RAM × 0.40, RAM − 3GB)
  - 8GB → 3.2GB / 16GB → 6.4GB / 32GB → 12.8GB
- **Layer 2 (warning, 선제 trim)** = soft × 1.5
  - 8GB → 4.8GB / 16GB → 9.6GB
  - 액션: HiRes 캐시 + PreviewImageCache 오래된 30% 만 trim (체감 영향 최소)
- **Layer 3 (emergency, 강제 flush)** = min(RAM × 0.65, RAM − 2GB)
  - 8GB → 5.2GB / 16GB → 10.4GB
  - 액션: 모든 옵션 캐시 전체 flush
- **OS memorypressure 신호 수신** → warning/critical 이벤트 발생 시 즉시 Layer 2/3 진입
- 로그: `[MemGuard] 초기화 — RAM 16GB / soft 6144MB / warn 9216MB / emerg 11264MB`

### ✅ #1 하위폴더 스트리밍 + 병렬 스캔
- `FileMatchingService.scanAndMatchStreaming()` 신규 API
- 최상위 서브폴더 병렬 스캔 (SSD: 최대 4 동시, HDD/NAS: 1)
- 배치 단위 콜백 → `photos.append` 점진 업데이트 → **첫 사진 ~200ms 내** 표시
- 3대 카메라 시나리오 (SD1/SD2/SD3 × 2000장 = 6000장) 체감 3~5배 향상 예상
- 로그: `[SCAN] streaming total 6000 photos in 1234ms (parallel=3)`

### ✅ 썸네일 그리드 러버밴드(Marquee) 선택
- 빈 영역에서 드래그 → 사각형 표시 + 교차 셀 라이브 선택
- Cmd/Shift + 드래그: 기존 선택 유지
- PreferenceKey 로 셀 프레임 수집 → CGRect.intersects 판정
- **("썸네일 뷰 마우스 드래그 안 되는" 최대 단점 해결)**

### ✅ 회전 기능 안정화
- 빠르게 연속 클릭해도 회전 어긋남 없음 (serial queue)
- JPG 이중 회전 버그 수정
- 미리보기 + 다중선택 프리뷰 + 필름스트립 모두 즉시 반영

---

## 📋 아침에 함께 볼 이슈 (수정 안 하고 기록만)

### 🔴 크리티컬 의심 (동작 버그 가능)
| 위치 | 경고 | 의미 |
|------|------|------|
| `ContentView+Toolbar.swift:654` | code after 'return' will never be executed | **죽은 코드** — return 뒤 `.frame()` 호출이 실행 안 됨. 의도한 UI 설정이 빠졌을 가능성 |
| `ThumbnailGridView.swift:3016:42` | variable 'self' was written to, but never read | 코드 로직 오류 의심. 확인 필요 |
| `ClaudeVisionService.swift:599` | reference to captured var 'results' in concurrently-executing code | **동시성 race condition** — Swift 6 에서 에러. AI 분석 결과 누락 가능성 |
| `PhotoStore+Folder.swift:454` | result of call to 'process(...)' is unused | 리턴 값 무시. 실패 신호를 감지 못할 수 있음 |
| `FileCopyService.swift:134-135`, `MemoryCardBackupService.swift:362-364` | result of 'fcntl' unused | 파일 락/플래그 설정 실패 시 감지 못함 |

### 🟡 클린업 (동작은 정상이지만 정리 필요)
- **Deprecated API 40곳**: `onChange(of:perform:)` macOS 14+ 에서 경고. 일괄 변환 가능.
- **Deprecated API 2곳**: `usesCPUOnly` (Vision) — macOS 14 에서 동작 안 함
- **Deprecated API 2곳**: `kUTTypePNG/JPEG` (`CropView.swift:536`)
- **사용 안 하는 변수 ~15곳**: `avgR/avgG/avgB`, `totalPixels`, `width/height` 등
- **`var` → `let` 변환 가능 ~10곳**: SmartCullService, DevelopPipeline 등

### 🟢 구조적 개선 기회 (Deep analysis)
1. **ThumbnailGridView.swift 가 3900줄** — 너무 큼. LazyThumbnailWrapper / MarqueeSelection / ThumbnailCache 등 분리 권장
2. **ContentView.swift 가 아직 393줄 + 3개 extension** — Toolbar 756줄, FolderBrowser 1056줄, SupportingViews 1711줄. 추가 분할 가능
3. **`@State` 변수 과다**: PhotoPreviewView 에 15개 — PreviewViewState 로 더 옮기면 SwiftUI diff 비용 감소
4. **TetherService delegate 시그니처 불일치** — macOS 14+ 에서 optional requirement 매칭 실패 (단, 실제 동작엔 영향 미미)
5. **Swift 6 동시성** — ClaudeVisionService, VideoPlayerManager 등 Sendable/actor 문제 여러 곳. 다음 OS 업데이트 대비 필요

---

## 🔍 GitHub 업그레이드 아이디어 후보 (차주 논의)

### 사진관리/선별 앱에서 자주 쓰이는 오픈소스
- **`darktable`** — 비파괴 보정 참조. 우리도 DevelopPipeline 있지만 확장 여지 많음 (커브, HSL, 노이즈 감소 알고리즘)
- **`fzf` 검색 UX** — 파일 수천장에서 fuzzy search 로 빠르게 찾기
- **`exiv2`** — 우리 ExifService 대체/보강. 특히 MakerNotes 읽기/쓰기가 더 안정적
- **Apple `PhotoKit`** — iCloud 사진 연동 가능성

### 특화 알고리즘
- **CLIP (Contrastive Language-Image Pretraining)** — "부케 든 사진" 같은 의미 검색. Core ML 변환 가능
- **`face_recognition` (dlib 기반)** — 현재 Vision 얼굴 그룹핑 보조 지표로 활용
- **Hybrid RAW decode** — libraw 옵션 추가 (Sony ARW 변형 대응)

### UX 참조
- **Apple Photos** 의 "People" view — 얼굴 태깅 UX 벤치마크
- **Lightroom Mobile** 의 flagging/rating 단축키 — 우리도 Q/W/E 스타일 고려
- **Capture One** 의 Loupe overlay — 부분 줌 돋보기 (현재 우리에 없음)

---

## 🎯 다음 세션 우선순위 제안

1. **아침 확인**: v8.6.3 변경 사항 (메모리 / 스트리밍 / 러버밴드) 테스트 + 피드백
2. **크리티컬 경고 4개** 하나씩 검토 (ContentView+Toolbar 죽은코드, ThumbnailGridView 3016, 등)
3. **Deprecated API 일괄 변환** — 자동 스크립트 가능 (onChange 40곳 한번에)
4. **배포 (v8.6.3)** — Release 빌드 + 공증 + DMG 교체

---

## 🚧 아직 안 건드린 것 (아침에 결정)

- #2 AI 분류 (v8.7 로드맵 — 얼굴 이름 태깅 → CLIP 의미 검색)
- Lite/Pro 분리 IAP 구현 (설계 완료, 구현 미진행)
- ThumbnailGridView 모듈 분할 (안전한 리팩토링)
- 테스터 김남훈 피드백 기반 기능 (범위 필터 등)

---

*이 보고서는 새벽 작업 중 생성되었습니다. 함께 보고 우선순위 합의 후 진행.*
