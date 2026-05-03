# PickShot AI 기능 심층 분석 보고서

> 작성일: 2026-05-02 (v9.1 갱신: 2026-05-03)  
> 분석 대상: v9.1 기준 codebase  
> 분석 범위: `PhotoRawManager/Services/` + `Services/AI/` 내 AI 관련 서비스 전체

---

## 1. 개요

PickShot의 AI 시스템은 **두 개의 레이어**로 이루어진다. 첫 번째 레이어는 완전 온디바이스 처리로, Apple Vision Framework(VNRequest 계열), 번들된 CoreML 모델(AdaFaceR18 / NIMAAesthetic / MobileCLIPImage / MobileCLIPText), 그리고 순수 픽셀 연산(pHash, Laplacian, Sobel) 으로 구성된다. 두 번째 레이어는 클라우드 API로, Claude API(Haiku 4.5 기본 / Sonnet 4.6 선택)와 Gemini API(2.5-Flash 기본 / 2.5-Pro 선택)를 사용한다.

번들된 CoreML 모델은 총 4종이다: `AdaFaceR18.mlpackage`(얼굴 인식, 512-dim), `NIMAAesthetic.mlpackage`(미적 점수), `MobileCLIPImage.mlpackage`(이미지 임베딩, 512-dim), `MobileCLIPText.mlpackage`(텍스트 임베딩, 512-dim).

전체 AI 기능 수는 **25개** 이상이며, 그 중 **5개**(스마트 셀렉, 얼굴 그룹핑, 연사 베스트, 시맨틱 검색, 비주얼 검색)는 FeatureGate에서 `comingSoon` 상태다.

> **중요 — 출시 전략 맥락**: PickShot 은 **Simple ₩2,900 / Pro ₩8,900** 두 티어로 출시 예정 ([TierManager.swift](../PhotoRawManager/Services/TierManager.swift)).  
> `comingSoon` 표시된 5개 AI 기능 + 테더링 + .pickshot 파일 import 는 **버그가 아니라 Pro 티어 출시까지의 의도적 봉인**이다 ([FeatureGate.swift:117-135](../PhotoRawManager/Services/FeatureGate.swift)). 코드는 거의 완성되어 있으며, Pro 출시 시점에 `releaseStatus` 를 `.released` 로 바꾸고 추가 모델 파일(`PhotoEnhancer.mlmodelc`, `NIMATechnical.mlpackage` 등)을 번들하면 즉시 사용 가능. 이 보고서의 "개선 제안" 섹션은 그 맥락을 반영해 **현재 출시 차단 이슈** 와 **Pro 출시 시 해결 항목** 을 분리한다.

---

## 2. 기능 카탈로그

| 기능명 | 서비스 파일 | 모델 / 프레임워크 | 트리거 | 온디바이스 / 클라우드 | 비용 |
|--------|-----------|-----------------|--------|----------------------|------|
| 품질 분석 (선명도/노출/흔들림) | `ImageAnalysisService` | Accelerate Laplacian, VNSaliency | 사용자 액션 (메뉴/툴바) | 온디바이스 | 무료 |
| 눈 감김 / 표정 감지 | `ImageAnalysisService` | VNDetectFaceLandmarksRequest Rev3 | 품질 분석 서브태스크 | 온디바이스 | 무료 |
| 얼굴 포커스 감지 | `ImageAnalysisService` | Vision + Laplacian | 품질 분석 서브태스크 | 온디바이스 | 무료 |
| NIMA 미적 점수 | `NIMAService` | NIMAAesthetic.mlpackage (CoreML) | 품질 분석 서브태스크 | 온디바이스 | 무료 |
| 장면 분류 (sceneTag) | `PhotoStore` / `AdvancedClassificationService` | VNClassifyImageRequest + Vision Pipeline | AI 분류 메뉴 | 온디바이스 | 무료 |
| 고급 분류 (색상/구도/시간대/텍스트/포즈) | `AdvancedClassificationService` | VNClassify + VNDetectHuman + VNRecognizeText + VNDetectBodyPose | AI 분류 서브태스크 | 온디바이스 | 무료 |
| 키워드 태깅 | `KeywordTaggingService` | 장면분류 결과 후처리 (사전 매핑) | 장면 분류 완료 후 자동 | 온디바이스 | 무료 |
| 자동 보정 (수평/노출/WB) | `ImageCorrectionService` | VNDetectHorizonRequest, CIAutoAdjustmentFilters | 사용자 액션 | 온디바이스 | 무료 |
| 원근 보정 (Upright) | `PerspectiveCorrectionService` | LSD 직선 감지 + RANSAC 소실점 + CIFilter | 사용자 액션 | 온디바이스 | 무료 |
| 스마트 크롭 | `SmartCropService` | VNGenerateAttentionBasedSaliencyImageRequest + VNDetectFaceRectanglesRequest | 사용자 액션 | 온디바이스 | 무료 |
| 얼굴 그룹핑 | `FaceGroupingService` | AdaFaceR18 CoreML (512-dim) → fallback VNFeaturePrint | 메뉴 (comingSoon) | 온디바이스 | 무료 |
| 스마트 셀렉 (SmartCull) | `SmartCullService` | VNFeaturePrintObservation (장르별 임계값) | SmartCullView (comingSoon) | 온디바이스 | 무료 |
| 연사 감지 | `BurstDetectionService` | EXIF 시간 + MobileCLIP 코사인 유사도 | 폴더 로드 후 자동 / on-demand | 온디바이스 | 무료 |
| 연사 베스트 선별 | `BurstPickerService` | Vision Landmarks + Saliency + Laplacian | BurstPickerDialog (comingSoon) | 온디바이스 | 무료 |
| 이미지 임베딩 | `ImageEmbeddingService` | MobileCLIPImage.mlpackage (CoreML, ANE) | 폴더 진입 시 백그라운드 자동 | 온디바이스 | 무료 |
| 텍스트 임베딩 | `TextEncoderService` | MobileCLIPText.mlpackage + CLIPTokenizer | 시맨틱 검색 쿼리 시 | 온디바이스 | 무료 |
| 시맨틱 검색 | `SemanticSearchService` | MobileCLIP (이미지/텍스트) + EmbeddingIndex SQLite | 폴더 진입 자동 인덱싱 + 검색 액션 (comingSoon) | 온디바이스 | 무료 |
| 비주얼 검색 | `VisualSearchService` | AdaFace / MobileCLIP / VNFeaturePrint (모드별 선택) | 드래그 영역 선택 → 검색 (comingSoon) | 온디바이스 | 무료 |
| 얼굴 임베딩 검색 | `FaceEmbeddingService` | VNDetectFaceLandmarks (152-dim) → ArcFace Phase2 교체 예정 | VisualSearchService 서브 | 온디바이스 | 무료 |
| 이미지 유사도 매칭 (pHash) | `AISimilarityService` | DCT 기반 pHash + EXIF 날짜 | 클라이언트 사진 매칭 | 온디바이스 | 무료 |
| AI 보정 (NPU) | `AIEnhanceService` | PhotoEnhancer.mlmodelc (번들 없음 시 CIFilter fallback) | 자동 보정 옵션 체크 시 | 온디바이스 | 무료 |
| 사용자 스타일 학습 (레거시) | `StyleLearner` | VNFeaturePrintObservation (코사인 유사도) | 셀렉 완료 후 자동 | 온디바이스 | 무료 |
| 사용자 선호도 프로파일 | `UserPreferenceService` | MobileCLIP 임베딩 평균 (positive/negative centroid) | BurstPickerCriteria.useUserPreference | 온디바이스 | 무료 |
| Claude Vision 분석 | `ClaudeVisionService` | Claude Haiku 4.5 / Sonnet 4.6 | AIAnalysisView 버튼 / AI 보정 | 클라우드 | 유료 (Haiku ~$0.25/M) |
| Gemini Vision 분석 | `GeminiService` | Gemini 2.5-Flash / 2.5-Pro | AIAnalysisView 버튼 | 클라우드 | 유료 (Flash ~$0.15/M) |

---

## 3. 기능별 상세

### 3.1 품질 분석 — `ImageAnalysisService.swift` (932줄)

**무엇을 하는가**: 사진 1장의 선명도·노출·흔들림을 픽셀 단위로 분석하고 QualityAnalysis를 생성한다.

**모델/프레임워크**:
- 썸네일 디코딩: HWJPEGDecoder(VideoToolbox) 또는 CGImageSource (400px 축소)
- 선명도: Laplacian (`MetalImageProcessor.laplacianSharpness`) — GPU 가속, Accelerate 폴백
- 흔들림: 수평·수직 Sobel 에너지 비율 (`detectMotionBlur`)
- 구도: `VNGenerateAttentionBasedSaliencyImageRequest` → RMS 거리 기반 compositionScore
- 얼굴·눈: `VNDetectFaceLandmarksRequest Rev3` + 속눈썹 랜드마크 거리 비율 (임계값 0.18)
- 스마일: 입꼬리 랜드마크 기반 미소 점수

**트리거**: `PhotoStore.runAnalysis()` → 툴바 "분석" 버튼 또는 메뉴

**입력/출력**:
- 입력: `PhotoItem.jpgURL`, EXIF(`AnalysisOptions`)
- 출력: `PhotoItem.quality` (`QualityAnalysis`) — sharpnessScore, brightnessScore, contrastScore, compositionScore, nimaScore, issues[], smileScore

**온디바이스**: 완전 온디바이스. 네트워크 없음.

**성능**:
- 배치: `OperationQueue` + `SystemSpec.imageAnalysisConcurrency()` (머신 tier 기반 캡)
- 메모리: 분석당 ~20MB (1280px CGImage + landmarks + saliency)
- M1 Pro 기준 동시성 3으로 캡

**한계**:
- EXIF 없을 경우 `ShootingIntent` 미감지 → 아웃포커싱/장노출 보정 안 됨
- 400px 축소 썸네일 기반이라 미묘한 포커스 미스는 놓칠 수 있음 (코드 주석에 명시 없으나 설계상 한계)

---

### 3.2 NIMA 미적 점수 — `NIMAService.swift`

**무엇을 하는가**: CoreML NIMAAesthetic 모델로 사진 미적 품질을 1~10점으로 평가한다.

**모델/프레임워크**: `NIMAAesthetic.mlpackage` (번들 포함) + 선택적 `NIMATechnical.mlpackage` (미포함)
- 입력: 224×224 썸네일 → `VNCoreMLRequest`
- 출력: 10-element softmax → 가중 평균 점수

**트리거**: `ImageAnalysisService` 배치 분석 안에 포함되거나 독립 배치(`NIMAService.scoreBatch`)

**입력/출력**:
- 입력: CGImage (224px)
- 출력: `QualityAnalysis.nimaScore` (1.0~10.0) → `QualityAnalysis.score` 계산에 우선 사용

**온디바이스**: ANE/GPU 우선 (`MLComputeUnits.all`)

**성능**: `DispatchQueue.concurrentPerform` + autoreleasepool. NIMATechnical 모델 번들 없으면 aesthetic 단독 사용.

**한계**: `NIMATechnical.mlpackage` 파일이 번들에 없음 → combinedScore에서 technical 항목 항상 nil. 코드는 지원하지만 실제 실행 불가.

---

### 3.3 얼굴 그룹핑 — `FaceGroupingService.swift` (640줄)

**무엇을 하는가**: 폴더 내 사진들을 같은 인물끼리 자동으로 그룹핑한다.

**모델/프레임워크**:
- 우선: `AdaFaceR18.mlpackage` (CoreML, 512-dim 임베딩, MIT License) — `AdaFaceService.isAvailable` 체크
- 폴백: `VNFeaturePrintObservation` 코사인 유사도

**트리거**: `FeatureGate.comingSoon` → 현재 비활성. `PhotoStore.isGroupingFaces` 플래그로 진행 표시.

**입력/출력**:
- 입력: `PhotoItem.jpgURL` 배열
- 출력: `FaceGroupResult` → `PhotoItem.faceGroupID` (Int), `PhotoStore.faceGroups`, `PhotoStore.faceThumbnails`

**온디바이스**: 완전 온디바이스.

**성능**:
- 얼굴 감지(병렬) + AdaFace 추론(직렬, CoreML thread-safety 미보장)
- 비교 복잡도: O(N²). 비교 쌍 제한: 5000쌍
- 얼굴 감지 해상도: 1280px

**한계**:
- AdaFace 출력 이름이 `var_498`로 하드코딩되어 있어 모델 재학습/교체 시 이름 충돌 위험 (폴백 로직 있음)
- 코사인 임계값 하드코딩 (0.65 기본)

---

### 3.4 스마트 셀렉 — `SmartCullService.swift` (952줄)

**무엇을 하는가**: VNFeaturePrint 기반 유사도 클러스터링으로 사진을 그룹화하고, 각 클러스터에서 품질 최고 A컷을 자동 선정한다.

**모델/프레임워크**: `VNFeaturePrintObservation` (Apple Vision) — 장르별 유사도 임계값(0.15~0.60)

**트리거**: `SmartCullView` → `cullService.runSmartCull()`. `FeatureGate.comingSoon` → 비활성.

**입력/출력**:
- 입력: `[PhotoItem]`, `CullGenre`
- 출력: `SmartCullService.groups` ([PhotoGroup]) → `PhotoStore`에 적용 (colorLabel, bestInGroup)

**온디바이스**: 완전 온디바이스.

**성능**:
- 5단계 파이프라인: FeaturePrint 추출 → 시간 그룹 분리 → 유사도 클러스터링 → 메가클러스터 재분할 → A컷 선정
- 메가클러스터(30장+) 재분할 2회 반복 로직 있음
- 룩북 장르는 색상 시그니처(6차원 RGB) 추가 사용

**한계**:
- `autoThreshold` 계산이 샘플 거리 기반이라 극단적으로 유사하거나 이질적인 폴더에서는 임계값 오조정 가능성 있음
- 클러스터 결과가 메모리에만 유지됨 (재시작 시 재실행 필요)

---

### 3.5 시맨틱 검색 — `SemanticSearchService.swift` + `EmbeddingIndex.swift`

**무엇을 하는가**: MobileCLIP 임베딩 기반으로 이미지→이미지 또는 텍스트→이미지 유사도 검색을 제공한다.

**모델/프레임워크**:
- 이미지: `MobileCLIPImage.mlpackage` (512-dim, ANE 가속)
- 텍스트: `MobileCLIPText.mlpackage` + `CLIPTokenizer` (BPE 49408 vocab)
- 저장: SQLite3 (`~/Library/Application Support/PickShot/EmbeddingIndex/<폴더hash>.sqlite3`)

**트리거**:
- 폴더 진입 시 `SemanticSearchService.shared.startIndexing(...)` 자동 호출 (`ContentView.swift:552`)
- 검색: `KeyEventHandling.swift:446`에서 참조 이미지 기반 검색
- `FeatureGate.comingSoon` → UI 비활성

**입력/출력**:
- 입력: URL 배열 (인덱싱) 또는 쿼리 URL/텍스트
- 출력: `[(url: URL, score: Float)]` top-K 결과

**온디바이스**: 완전 온디바이스. SQLite WAL 모드, 16MB 캐시.

**성능**:
- 인덱싱: mtime 비교로 변경 파일만 재처리 (incremental)
- 검색: 전체 임베딩 메모리 캐시 (`_allCache`) → 폴더 재방문 시 DB 재로드 없음
- v8.9 버그: 저장된 DB mtime과 파일 mtime 비교 오류 수정됨 (코드 주석 확인)

**한계**:
- 텍스트 검색은 영어 권장 (한국어 낮은 정확도 — 코드 주석 명시)
- minScore=0.18 은 MobileCLIP text↔image cross-modal 특성상 낮은 값. 실제 결과 품질은 쿼리에 따라 크게 변동

---

### 3.6 비주얼 검색 — `VisualSearchService.swift` (29KB)

**무엇을 하는가**: 사용자가 드래그로 지정한 영역(얼굴/사물/의상)과 유사한 사진을 폴더 전체에서 찾는다.

**모델/프레임워크**:
- 얼굴 모드: `FaceEmbeddingService` (VNDetectFaceLandmarks 152-dim)
- 사물 모드: `MobileCLIPImage` (512-dim)
- 의상 모드: 인물 segmentation + torso crop + MobileCLIP
- Layer ②: VNFeaturePrint (인물 영역 — 옆면/뒷면 매칭 fallback)
- Layer ③: 전체 씬 VNFeaturePrint

**트리거**: `FeatureGate.comingSoon` → 비활성. 코드 상 드래그 영역 → `setReference()` 호출 구조.

**입력/출력**:
- 입력: `VisualSearchReference` (소스 URL + cropRect + 임베딩)
- 출력: `matchedURLs: Set<URL>` → `PhotoStore` 필터 적용

**성능**: 폴더별 검색 상태 LRU 캐시 (최근 폴더 결과 복원). 부정 학습(negativeExamples) 지원.

**한계**: `FaceEmbeddingService`의 기본 구현이 Vision Landmark 기반 (85% 정확도). ArcFace CoreML 교체는 Phase 2 예정으로 코드에 명시되어 있음.

---

### 3.7 연사 베스트 선별 — `BurstPickerService.swift` + `BurstDetectionService.swift`

**무엇을 하는가**: 연사 그룹에서 사용자 지정 기준(눈뜸/포커스/노출/미소/수평 등)으로 베스트 1장을 선정한다.

**모델/프레임워크**:
- 연사 감지: EXIF 촬영시각 간격(5초) + MobileCLIP 코사인 유사도(0.88 임계값)
- 베스트 선별: VNDetectFaceLandmarks + VNSaliency + Laplacian + 히스토그램
- 취향 반영: `UserPreferenceProfile` (CLIP 임베딩 centroid)

**트리거**: `BurstPickerDialog` → `BurstPickerService.shared.pickBest()`. `FeatureGate.comingSoon`.

**입력/출력**:
- 입력: `[[PhotoItem]]` (연사 그룹들), `BurstPickerCriteria`
- 출력: 각 그룹의 베스트 1장에 컬러라벨/SP/별점 부여

**성능**: GPU Metal CIContext 공유 (매 호출 재생성 방지). `BurstPickerCriteria` 장르 프리셋 3종(웨딩/인물/풍경).

---

### 3.8 Claude Vision 분석 — `ClaudeVisionService.swift` (31KB)

**무엇을 하는가**: Claude API에 사진을 전송해 자연어 분석·보정 제안·스타일 분석·평가·보정값 JSON을 받는다.

**모델**: `claude-haiku-4-5-20251001` (기본) / `claude-sonnet-4-6` (설정 변경 시)

**트리거**: `AIAnalysisView` 버튼들 (사진 설명 / 보정 제안 / 스타일 분석 / 전문가 평가 / AI 보정 적용)

**API 키 관리**: Keychain 우선 저장 (`claude_api_key`). UserDefaults 레거시 키 자동 마이그레이션. 메모리 캐시(`_apiKeyCache`)로 Keychain 반복 읽기 방지.

**입력/출력**:
- 입력: 이미지 URL (768px 리사이즈 base64) + 프롬프트
- 출력:
  - `describePhoto` → 한국어 설명 문자열
  - `getAICorrectionValues` → `AICorrectionValues` JSON (exposure, contrast, highlights, shadows, temperature, saturation, sharpness, horizonAngle, cropTop/Bottom/Left/Right, skipToneCurve)
  - 이후 `applyAICorrection`으로 CIFilter 파이프라인 적용 (softness=0.75)

**성능/비용**: `APIUsageTracker`로 토큰 누적 추적. 예산 설정($5 기본). max_tokens=1500.

**한계**: JSON 파싱에 try/catch 있으나 Claude가 마크다운 코드블록으로 감싸서 응답할 경우 `cleaned` 전처리로 제거하는 방어 코드 있음. 그럼에도 예상치 못한 포맷에서 실패 시 `invalidResponse` throw.

---

### 3.9 Gemini Vision 분석 — `GeminiService.swift`

**무엇을 하는가**: Gemini API를 통해 Claude와 동일한 분석/보정 기능을 대안 엔진으로 제공한다.

**모델**: `gemini-2.5-flash` (기본) / `gemini-2.5-pro`

**API 키 관리**: **UserDefaults에 평문 저장** (`GeminiAPIKey`). Claude와 달리 Keychain 미사용 — 보안 취약점.

**성능/비용**: `APIUsageTracker` 공유. temperature=0.1, responseMimeType=`application/json`으로 JSON 출력 강제.

---

### 3.10 이미지 유사도 매칭 — `AISimilarityService.swift`

**무엇을 하는가**: 카카오톡 등으로 전달된 클라이언트 사진과 원본을 파일명 무관하게 매칭한다.

**모델/프레임워크**: DCT 기반 pHash (64픽셀 그레이스케일) + EXIF 날짜 보조

**트리거**: 클라이언트 사진 매칭 기능 (ClientSelectService 연동 추정)

**성능**: 온디바이스, API 비용 없음. 주석에 "No API cost" 명시.

---

### 3.11 스마트 크롭 — `SmartCropService.swift` (276줄)

**무엇을 하는가**: 어텐션 히트맵 + 얼굴 위치 + 삼분할 법칙으로 최적 크롭 영역을 제안한다.

**모델/프레임워크**: `VNGenerateAttentionBasedSaliencyImageRequest` + `VNDetectFaceRectanglesRequest`

**트리거**: 편집 패널 또는 AI 보정 파이프라인 내부

---

### 3.12 원근 보정 — `PerspectiveCorrectionService.swift`

**무엇을 하는가**: LSD 직선 감지 → RANSAC 소실점 추정 → 카메라 회전 역산으로 라이트룸 Upright 수준의 원근 보정을 수행한다.

**모델/프레임워크**: 순수 수학 연산 (Accelerate + simd) + VNDetectFaceRectanglesRequest (인물 감지 시 Upright 건너뜀)

**트리거**: `ImageCorrectionService.autoCorrect` 내부 (`CorrectionOptions.autoUpright`)

---

### 3.13 AI 보정 (NPU) — `AIEnhanceService.swift` (406줄)

**무엇을 하는가**: `PhotoEnhancer.mlmodelc` CoreML 모델로 NPU 추론 보정을 수행하고, 모델 없으면 CIFilter 파이프라인으로 폴백한다.

**모델/프레임워크**: `PhotoEnhancer.mlmodelc` (번들 **미포함**) / 폴백: CIColorControls + CIVibrance + CIHighlightShadowAdjust 체인

**한계**: 번들에 `PhotoEnhancer.mlmodelc` 가 없으므로 실제로는 항상 CIFilter 폴백 사용. `isAIModelAvailable`은 항상 false.

---

### 3.14 사용자 스타일 학습 — `StyleLearner.swift` + `UserPreferenceProfile.swift`

두 서비스가 병존한다.

**StyleLearner (레거시)**: VNFeaturePrint 기반. 저장 경로: `~/.pickshot/style_profile.json`. 셀렉 완료 시 자동 학습.

**UserPreferenceProfile (v8.9 신규)**: MobileCLIP 임베딩 centroid (positive/negative). 저장 경로: `~/Library/Application Support/PickShot/user_preference.json`. 30장 이상 학습 시 `isTrained = true`. 프로필 export/import + 가중치 병합 지원.

---

### 3.15 셀렉 이벤트 저장 — `SelectionEventStore.swift`

**무엇을 하는가**: 사용자의 모든 셀렉 액션(별점/라벨/SP/내보내기/삭제 등)을 SQLite 원장으로 영속 기록한다.

저장 경로: `~/Library/Application Support/PickShot/selection_events.sqlite3`

설계 원칙: append-only (파괴적 업데이트 없음). polarity(positive/negative/neutral) 자동 분류. 이 원장이 `UserPreferenceProfile` 학습의 근거 데이터셋.

---

### 3.16 API 사용량 추적 — `APIUsageTracker.swift`

**무엇을 하는가**: Claude/Gemini 토큰 사용량과 예상 비용을 누적 추적한다.

저장: UserDefaults (`aiUsageInput`, `aiUsageOutput`, `aiUsageRequests`, `aiUsageBudget`).
엔진별 단가 하드코딩: Claude Haiku $0.25/$1.25, Sonnet $3.0/$15.0, Gemini Flash $0.15/$0.60, Pro $1.25/$10.0 (1M 토큰 기준).

---

## 4. 데이터 흐름

```
사용자 액션 (툴바/메뉴/단축키)
        │
        ▼
PhotoStore (상태 관리 허브)
  ├─ runAnalysis() ──────────────────────────────────┐
  │     │                                             │
  │     ▼                                             ▼
  │  ImageAnalysisService.analyzeBatch()       NIMAService.scoreBatch()
  │     │                                             │
  │     │  VNDetectFaceLandmarks                      │  NIMAAesthetic.mlpackage
  │     │  Laplacian / Sobel                          │
  │     ▼                                             │
  │  PhotoItem.quality (QualityAnalysis) ◄────────────┘
  │     └── sharpnessScore, brightnessScore, compositionScore
  │     └── issues[], nimaScore, smileScore, score(0~100)
  │
  ├─ classifyScenes() ──► AdvancedClassificationService
  │                             │  VNClassifyImageRequest
  │                             │  VNDetectFaceRectanglesRequest
  │                             │  VNRecognizeTextRequest
  │                             │  VNDetectHumanBodyPoseRequest
  │                             ▼
  │                       PhotoItem.sceneTag, .keywords[]
  │                       PhotoItem.colorMood, .compositionType, .timeOfDay
  │
  ├─ groupFaces() ──────► FaceGroupingService
  │                             │  AdaFaceR18.mlpackage (512-dim)
  │                             │  → fallback VNFeaturePrint
  │                             ▼
  │                       PhotoItem.faceGroupID
  │                       PhotoStore.faceGroups, .faceThumbnails
  │
  ├─ SmartCullService.runSmartCull() ─► VNFeaturePrintObservation
  │                             ▼
  │                       PhotoStore 적용 (colorLabel, isBestInGroup)
  │
폴더 진입 (자동 백그라운드)
  └─ SemanticSearchService.startIndexing()
         │  MobileCLIPImage.mlpackage (ANE)
         ▼
       EmbeddingIndex SQLite3 (폴더별 .sqlite3)
         │
         ├─ searchSimilar(url) → top-K 이미지 결과
         └─ searchByText(text) → TextEncoderService → top-K 결과

사용자 AI 분석 버튼 (AIAnalysisView)
  ├─ ClaudeVisionService.analyzeImage()
  │     │  Keychain API Key → HTTPS → api.anthropic.com
  │     │  이미지 768px base64 + 프롬프트
  │     ▼
  │   APIUsageTracker 누적
  │   PhotoItem.aiCategory, .aiDescription, .aiScore (등)
  │
  └─ GeminiService.analyzeImage()
        │  UserDefaults API Key → HTTPS → generativelanguage.googleapis.com
        ▼
      (동일 구조)

셀렉 액션 (별점/라벨/내보내기 등)
  └─ SelectionEventStore.record()
         │  SQLite3 append-only 원장
         └─ UserPreferenceService.train()
                │  MobileCLIP 임베딩 평균
                └─ user_preference.json (positive/negative centroid)
```

---

## 5. 성능 / 비용 종합 평가

### 무거운 기능 (처리 시간 주의)

| 기능 | 이유 | 현황 |
|------|------|------|
| 얼굴 그룹핑 | AdaFace 직렬 추론 + O(N²) 비교 | comingSoon — 미사용 |
| 스마트 셀렉 | VNFeaturePrint 전 사진 순회 + 클러스터링 | comingSoon — 미사용 |
| 시맨틱 인덱싱 | MobileCLIP ANE 추론 × 파일 수 | 백그라운드 자동, incremental |
| 품질 분석 배치 | 동시성 캡 있음, 분석당 ~20MB | SystemSpec tier 기반 안전 처리 |

### 잘 구현된 부분

1. **NIMA + 기존 점수 이중화**: NIMA가 없으면 Laplacian+노출+구도 조합으로 자동 폴백
2. **EmbeddingIndex incremental**: mtime 비교로 변경 파일만 재인덱싱
3. **ClaudeVisionService Keychain 캐시**: 매 SwiftUI 렌더링마다 Keychain 읽기 방지 (`_hasAPIKeyCache`)
4. **AdaFace fallback**: `VNFeaturePrint`로 자동 폴백하여 모델 파일 없어도 동작
5. **SelectionEventStore append-only**: 재학습/이관 가능한 원장 설계

---

## 6. 개선 제안 (코드 근거 있는 것만)

### A. 즉시 수정 — 현재 출시(Simple) 영향

#### 6.1 [보안] Gemini API 키 UserDefaults 평문 저장

**근거**: `GeminiService.swift:48` — `UserDefaults.standard.string(forKey: "GeminiAPIKey")`  
**문제**: Claude는 Keychain 저장(`KeychainService.save`)인데, Gemini는 UserDefaults에 평문 저장.  
**권장**: `ClaudeVisionService.setAPIKey / getAPIKey` 패턴과 동일하게 Keychain으로 변경. 이미 출시된 Simple 티어에서도 사용 가능한 기능이므로 보안 일관성 우선.

#### 6.4 [성능 누락] StyleLearner 벡터 캐시 메모리 무제한

**근거**: `StyleLearner.swift:17` — `private var vectorCache: [URL: [Float]] = [:]`  
**문제**: 캐시 크기 제한 없음. 대용량 폴더에서 모든 VNFeaturePrint 벡터가 메모리에 축적.  
**권장**: LRU 캐시 또는 최대 항목 수 제한 추가.

### 6.5 [중복] StyleLearner vs UserPreferenceProfile 병존

**근거**: 두 서비스 모두 "사용자 취향 학습" 을 수행하나 독립적으로 존재.
- `StyleLearner`: VNFeaturePrint 기반, `~/.pickshot/style_profile.json`
- `UserPreferenceProfile`: MobileCLIP 기반, `~/Library/Application Support/PickShot/user_preference.json`

**문제**: 저장 경로·임베딩 공간·API 모두 다른 두 시스템이 동시 유지됨. `StyleLearner`가 레거시임을 주석에서 시사하나 명시적 deprecation 없음.  
**권장**: `StyleLearner`를 `UserPreferenceProfile`로 통합하거나 명시적 deprecated 처리.

### 6.6 [설계] AdaFace 출력 이름 하드코딩

**근거**: `AdaFaceService.swift:91` — `output.featureValue(for: "var_498")`  
**문제**: 모델 재컴파일 또는 교체 시 출력 이름이 바뀌면 조용히 실패 후 폴백 로직으로 넘어감.  
**권장**: 출력 이름을 모델 로드 시 동적으로 읽도록 변경 (`output.featureNames`로 순회하는 폴백 코드가 있으나 주 경로가 하드코딩).

### B. Pro 출시 시 해결 항목 (현재 의도적 보류)

#### 6.7 [Pro 보류] AIEnhanceService — PhotoEnhancer 모델 번들

**근거**: `AIEnhanceService.swift:27` — `Bundle.main.url(forResource: "PhotoEnhancer", withExtension: "mlmodelc")` 반환 nil  
**현재 상태**: `isAIModelAvailable`이 항상 false → 항상 CIFilter 폴백 사용. 사용자에게는 "AI 보정"이라는 라벨이 보이지만 실제로는 일반 CIFilter 처리.  
**Pro 출시 시 조치**: 두 가지 중 택일.
1. PhotoEnhancer.mlmodelc 모델을 번들에 포함하여 Pro 전용 기능으로 활성화 → FeatureGate 에 `aiPhotoEnhance` 등 추가
2. AI 보정 자체를 제거하고 CIFilter 자동 보정만 유지 (Simple/Pro 공통)

**현재 임시 조치 권장**: UI 라벨을 "AI 보정" → "자동 보정" 으로 변경해서 Simple 사용자 오해 방지.

#### 6.8 [Pro 보류] NIMATechnical 모델 번들

**근거**: `NIMAService.swift:117` — `NIMATechnical.mlmodelc/mlmodel` 조회 nil  
**현재 상태**: `combinedScore`에서 technical 항목이 항상 nil → aesthetic 60% 가중만 적용. 설계는 "aesthetic 60% + technical 40%" 이나 실제는 100% aesthetic.  
**영향 범위**: 품질 점수가 미적 점수 한 축으로만 결정됨. 흔들림/노이즈가 있어도 미적 구도가 좋으면 점수가 높게 나올 수 있음.  
**Pro 출시 시 조치**: NIMATechnical 모델 번들 포함하여 Pro 티어 자동 활성화. 별도 FeatureGate 불필요 — `isTechnicalAvailable` 가드로 자연 폴백.

#### 6.9 [Pro 출시 게이트] comingSoon 7개 활성화 체크리스트

| 기능 | 현재 상태 | 출시 전 검증 항목 |
|------|----------|-----------------|
| `burstBestAuto` | 코드 완성, 게이트만 닫힘 | 1만장 폴더 5분 안에 완료되는지 실측 |
| `faceGrouping` | AdaFace 추론 완성 | 출력 이름 하드코딩(6.6) 해결, O(N²) 캡 5000 적정성 검증 |
| `smartCull` | 952줄 — 가장 무거움 | 장르별 임계값 캘리브레이션 데이터 필요 |
| `semanticSearch` | EmbeddingIndex 완성 | 인덱싱 진행률 UI 가시성, 검색 응답 속도 측정 |
| `visualSearch` | 모드별 라우팅 완성 | 드래그 영역 → 검색 트리거 UX 검증 |
| `tethering` | 안정성 미흡 (FeatureGate.swift:130 주석) | 카메라 모델별 호환성 테스트 |
| `pickshotFileImport` | "협업 워크플로우 미완성" | 파일 포맷 명세 + 충돌 해결 정책 |

---

## 7. Simple / Pro 티어 분리 권장 매핑

현재 [FeatureGate.swift](../PhotoRawManager/Services/FeatureGate.swift) 는 모든 게이팅 기능이 `requiresPro = true` 다. 즉 Simple 티어는 **베이스 앱** (게이팅 없는 기능 전부) 만 사용. [TierManager.swift](../PhotoRawManager/Services/TierManager.swift) 에서 가격은 Simple ₩2,900 / Pro ₩8,900.

### Simple ₩2,900 — 코어 컬링 워크플로우

게이트 없이 사용 가능한 모든 기능. 분석 결과 다음이 포함됨:

- 사진 뷰잉 (필름스트립, 그리드, 풀스크린)
- 별점·컬러라벨·SP·G셀렉
- 품질 분석 (선명도/노출/흔들림/눈감김/포커스)
- NIMA 미적 점수 (aesthetic 단축, Technical 폴백)
- 장면 분류 + 키워드 태깅
- 자동 보정 (수평/노출/WB) + 원근 보정 + 스마트 크롭
- 이미지 유사도 매칭 (pHash) — 클라이언트 사진 매칭
- Claude / Gemini Vision 분석 (사용자 본인 API 키 사용)
- 수동 컬링 일반 워크플로우

### Pro ₩8,900 — AI 자동화 + 클라이언트 워크플로우 + 고급 출력

`FeatureGate` 의 모든 항목 (`requiresPro = true`).

**Pro 결정타 (코드 완성됨, 이미 released 상태 — 게이팅 정상 작동)**
- 클라이언트 셀렉 (`clientSelect`, `clientWebViewer`)
- Google Drive 업로드 (`driveUpload`)
- RAW→JPG 변환 (`rawToJpgConvert`)
- 배치 처리 (`batchProcess`)
- 컨택트시트 PDF (`contactSheetPDF`)
- 적극 캐시 모드 (`aggressiveCache`)
- LOG 영상 자동 LUT (`logAutoLUT`)
- Lightroom 양방향 (`lightroomBidirectional`)
- 폴더 구조 보존 (`folderStructurePreserve`)
- 연속 메모리카드 백업 (`continuousCardBackup`)

**Pro v9.x 추가 예정 (현재 comingSoon)**
- 연사 베스트 자동 (`burstBestAuto`)
- 얼굴 그룹핑 (`faceGrouping`)
- 스마트 셀렉 (`smartCull`)
- 시맨틱 검색 (`semanticSearch`)
- 비슷한 사진 찾기 (`visualSearch`)
- 카메라 테더링 (`tethering`)
- .pickshot 파일 협업 (`pickshotFileImport`)

### 출시 전략 제안

**1단계 — 현재 (Simple+Pro 동시 출시)**
- `comingSoon` 7개를 모두 막아둔 채로 Simple/Pro 분리 출시
- Pro 가치는 클라이언트 워크플로우 + RAW 변환 + 배치 처리 + 캐시 모드 + LUT + Lightroom + 메모리카드 백업으로 충분히 차별화됨
- Simple 사용자는 코어 컬링 + 기본 AI 분석 (Claude/Gemini API 키 사용 시) 으로 베이직 워크플로우 완결

**2단계 — Pro v9.x (AI 봉인 해제)**
- `burstBestAuto` 우선 (마케팅 임팩트 큼: "1만장 30분→5분")
- `faceGrouping` 다음 (AdaFace 모델 이미 번들됨, 게이트만 해제하면 즉시 동작)
- `smartCull` / `semanticSearch` / `visualSearch` 는 캘리브레이션 + UX 다듬은 후

**3단계 — Pro 차별화 강화**
- PhotoEnhancer / NIMATechnical 모델 번들 → AI 보정 / 정밀 품질 점수 Pro 전용으로 승격
- 새 FeatureGate 항목 추가: `aiPhotoEnhance`, `nimaTechnicalScore`

### 게이트 표시 정책 (UX 일관성)

현재 [ContentView+Toolbar.swift](../PhotoRawManager/Views/ContentView+Toolbar.swift) 에서 메뉴 항목에:
- `lock.fill` (보라색) — Pro 잠금 (구독으로 해제 가능)
- `hourglass` (주황색) — `comingSoon` (구독해도 못 씀, 추후 공개)

이 두 표시가 섞여 있는데, **사용자가 "구독했는데 왜 안 됨?" 으로 혼란할 수 있음**. Simple 출시 전에 `comingSoon` 항목은:
- 메뉴에서 아예 숨기기 (가장 깔끔), 또는
- "v9.x 공개 예정" 배지 + 비활성

**권장**: **숨기기**. comingSoon 기능 7개 메뉴 항목을 `if FeatureGate.isComingSoon(.x) { EmptyView() }` 로 처리. Pro 업데이트 시 게이트 해제하면 자연스럽게 나타남.

---

## 부록 A. 번들 CoreML 모델 목록

| 파일 | 용도 | 번들 포함 |
|------|------|----------|
| `AdaFaceR18.mlpackage` | 얼굴 임베딩 512-dim | 포함 |
| `NIMAAesthetic.mlpackage` | 미적 점수 1~10 | 포함 |
| `MobileCLIPImage.mlpackage` | 이미지 임베딩 512-dim | 포함 |
| `MobileCLIPText.mlpackage` | 텍스트 임베딩 512-dim | 포함 |
| `PhotoEnhancer.mlmodelc` | AI 보정 | **미포함** (코드만 존재) |
| `Denoiser.mlmodelc` | AI 디노이즈 | **미포함** (코드만 존재) |
| `NIMATechnical.mlpackage` | 기술 품질 점수 | **미포함** (코드만 존재) |

---

## 부록 B. AI 데이터 저장 경로

| 데이터 | 경로 | 형식 |
|--------|------|------|
| CLIP 임베딩 인덱스 | `~/Library/Application Support/PickShot/EmbeddingIndex/<폴더hash>.sqlite3` | SQLite3 WAL |
| 셀렉 이벤트 원장 | `~/Library/Application Support/PickShot/selection_events.sqlite3` | SQLite3 append-only |
| 사용자 선호 프로파일 | `~/Library/Application Support/PickShot/user_preference.json` | JSON (Codable) |
| 스타일 학습 (레거시) | `~/.pickshot/style_profile.json` | JSON |
| Claude API 키 | macOS Keychain (`claude_api_key`) | Keychain |
| Gemini API 키 | UserDefaults (`GeminiAPIKey`) | 평문 |
| API 사용량 | UserDefaults (`aiUsageInput`, `aiUsageOutput`, `aiUsageRequests`) | UserDefaults |

---

## 부록 C. Simple / Pro / comingSoon 구분

| 기능 | 티어 | 출시 상태 | 비고 |
|------|------|----------|------|
| 사진 뷰잉 / 별점 / 컬러라벨 / SP / G셀렉 | Simple+ | released | 비게이팅 |
| 품질 분석 (선명도/노출/흔들림/눈감김) | Simple+ | released | 비게이팅 |
| NIMA 미적 점수 | Simple+ | released | Aesthetic만 (Technical 폴백) |
| 장면 분류 + 키워드 태깅 | Simple+ | released | 비게이팅 |
| 자동 보정 / 원근 보정 / 스마트 크롭 | Simple+ | released | 비게이팅 |
| Claude / Gemini AI 분석 | Simple+ | released | 사용자 본인 API 키 |
| pHash 이미지 유사도 매칭 | Simple+ | released | 비게이팅 |
| 클라이언트 셀렉 (G-Select 웹뷰어) | Pro | released | FeatureGate.clientSelect |
| Google Drive 업로드 | Pro | released | FeatureGate.driveUpload |
| RAW → JPG 변환 | Pro | released | FeatureGate.rawToJpgConvert |
| 배치 처리 (워터마크 등) | Pro | released | FeatureGate.batchProcess |
| 컨택트시트 PDF | Pro | released | FeatureGate.contactSheetPDF |
| 적극 캐시 모드 | Pro | released | FeatureGate.aggressiveCache |
| LOG 영상 자동 LUT | Pro | released | FeatureGate.logAutoLUT |
| Lightroom 양방향 (XMP) | Pro | released | FeatureGate.lightroomBidirectional |
| 원본 폴더 구조 유지 | Pro | released | FeatureGate.folderStructurePreserve |
| 연속 메모리카드 백업 | Pro | released | FeatureGate.continuousCardBackup |
| 연사 베스트 자동 선별 | Pro | **comingSoon** | Pro v9.x 예정 |
| 얼굴 그룹 · 이름 태그 | Pro | **comingSoon** | Pro v9.x 예정 |
| 스마트 셀렉 (SmartCull) | Pro | **comingSoon** | Pro v9.x 예정 |
| 의미 기반 검색 (CLIP) | Pro | **comingSoon** | Pro v9.x 예정 |
| 비슷한 사진 찾기 (Visual) | Pro | **comingSoon** | Pro v9.x 예정 |
| 카메라 테더링 | Pro | **comingSoon** | 안정성 미흡 |
| .pickshot 파일 import | Pro | **comingSoon** | 협업 워크플로우 미완성 |

