# RAW 편집 엔진 심층 분석 (2026-04-21)

**대상**: `DevelopPipeline.swift` (현재 브랜치 `feature/list-view-nstableview`)
**관련 브랜치**: `raw-metal-engine` (libraw + Metal 실험적 구현, 현재 미사용)

---

## 🐛 사용자 보고 문제

1. **노출 슬라이더 조작 시 이미지 회전** — 원래 미리보기와 다른 방향
2. **색감이 원래 미리보기와 달라짐** — 보정 시작하면 색상이 바뀜

---

## 🔍 원인 분석

### 1. 회전 문제 — 구조적 이슈 + 엣지 케이스

#### 정상 플로우 (기대값)

```
[Stage 1] 임베디드 JPG 로드
  → HWJPEGDecoder 또는 CGImageSourceCreateThumbnailAtIndex
    (kCGImageSourceCreateThumbnailWithTransform: true)
  → EXIF orient 자동 적용됨 → 화면에 upright 로 표시
  → self.image 에 저장 (portrait → tall, landscape → wide)

[슬라이더 이동] refreshDevelopedImage()
  │
  ├─ [Fast] renderFast(baseImage: self.image)
  │    → CI 필터 적용 → upright 유지
  │    → enforceAspectOfStage1() → Stage1 과 aspect 같음 → 통과
  │
  └─ [Quality — 300ms idle] render(url: RAW)
       → loadCIImageWithInfo:
         ├─ CIRAWFilter.outputImage = sensor orient (ARW 센서는 landscape)
         ├─ EXIF orient 읽어 oriented(cgOri) 적용 → display orient 로 변환
         └─ CGImage 로 bake → 캐시 저장
       → applyFilters() → extent 유지
       → makeNSImage() → NSImage 반환
       → enforceAspectOfStage1() → 같은 aspect → 통과
```

#### 잠재적 버그 지점

**A. Stage 1 orient 미적용**
- 일부 RAW 파일은 `kCGImageSourceCreateThumbnailWithTransform` 이 제대로 작동 안 함
  - Sony ARW 은 내장 JPG 에 자체 EXIF orient 태그 있지만, CGImageSource 가 놓치는 경우 존재
- 이 경우 Stage 1 = landscape, Quality = portrait → `enforceAspectOfStage1` 이 Quality 를 landscape 로 다시 회전 → **잘못된 결과**

**B. Apple CIRAWFilter 의 orient 자동 적용 여부 변화**
- macOS 버전별로 CIRAWFilter 의 `outputImage` orient 동작이 약간 다름
- macOS 14+ 에서는 일부 RAW 에 대해 이미 orient 를 적용한 채 반환하는 케이스 있음
- 우리 코드는 **항상 수동 적용** → 일부 macOS 에서 **이중 회전** 가능

**C. 캐시 stale**
- `rawBaseCache` 키: `(url, scaleFactor, exposure, temp, tint, wbAuto)` 만 포함
- 만약 첫 로드에서 orient 가 잘못 적용됐으면 캐시가 잘못된 상태로 남아 계속 잘못 표시

**D. straighten 필터**
- `settings.cropRotation` 이 작은 각도(소수점) 라도 있으면 `CIFilter.straighten` 이 이미지 회전
- 부드러운 orient 변환이라 돌아가 보일 수 있음
- 사용자가 수평 보정 자동 감지 기능 사용 후 잔존값 있을 수 있음

### 2. 색감 차이 — 구조적

**원인**: 임베디드 JPG 와 CIRAWFilter 출력은 **완전히 다른 색 파이프라인**

| 항목 | 임베디드 JPG | CIRAWFilter 출력 |
|---|---|---|
| 톤 커브 | 카메라 "Standard" 픽처 스타일 (S-curve) | Apple 의 neutral baseline |
| 채도 | 카메라 기본 채도 boost (~+15%) | 1.0 (boost 없음) |
| 대비 | 카메라 "Standard" 대비 부스트 | neutral |
| WB | 카메라 결정 WB | "as-shot" WB (정확하지만 덜 따뜻함) |
| 샤프닝 | 카메라 내 샤프닝 | 없음 |

**결론**: 이 차이는 **버그가 아니라 의도된 동작**. 단지 "원래 미리보기와 다르다" 는 사용자 기대를 충족 못 함.

#### 해결 접근법

| 방법 | 복잡도 | 효과 |
|---|---|---|
| 1. 기본값에서 baseline 톤/채도 부스트 적용 | 🟢 낮음 | JPG 와 비슷한 시작점 |
| 2. CIRAWFilter 의 `boostAmount` / `boostShadowAmount` 조정 | 🟢 낮음 | Apple API 활용 |
| 3. DCP (DNG Camera Profile) 프로파일 파싱/적용 | 🔴 높음 | 완벽한 카메라 매칭 |
| 4. 카메라별 embedded JPG tone curve 추출 | 🔴 매우 높음 | 완벽하지만 리버스 엔지 필요 |

**추천**: 방법 1+2 조합. `baselineTone` 설정을 `DevelopSettings` 에 추가해 사용자가 "Neutral / Standard / Vivid" 선택.

---

## 🔧 즉시 적용 가능한 수정

### Fix A — 진단 로깅 추가
회전 문제 재현 시 원인 파악을 위해. 배포본엔 `.isDebug` 플래그 뒤에 숨김 가능.

### Fix B — enforceAspectOfStage1 호출 조건 강화
Quality render 경로에서는 이미 CIRAWFilter + 수동 orient 를 적용했으므로, Stage 1 과 aspect 가 다르면 **정상** 상황일 수 있음 (Stage 1 orient 실패 케이스). 현재 코드는 무조건 Stage 1 에 맞추려 회전 → 이게 반대로 꼬일 수 있음.

**수정안**:
- Quality 경로는 EXIF 기준 orient 를 "진실" 로 받아들이고, Stage 1 이 틀렸다면 Stage 1 측을 수정해야 함
- `enforceAspectOfStage1` 을 Quality 에선 **생략**

### Fix C — Baseline 톤/채도 (색감 일치)
CIRAWFilter 로드 후 applyFilters 에서 default baseline 적용:

```swift
// applyFilters 말미:
if !skipExposureAndManualWB {
    // Non-RAW: 기존 필터 체인 그대로
} else {
    // RAW 경로: baseline 톤/채도 약간 부스트해 JPG 에 가깝게
    let baseline = CIFilter.colorControls()
    baseline.inputImage = image
    baseline.saturation = 1.15  // +15%
    baseline.contrast = 1.08    // +8% S-curve 효과
    if let out = baseline.outputImage { image = out }
}
```

### Fix D — CIRAWFilter boostAmount 활용
```swift
raw.exposure = Float(settings.exposure)
raw.boostAmount = 1.0              // Apple 기본. 0.75 로 낮추면 neutral, 1.25 로 vivid
raw.boostShadowAmount = 0.0        // 0.5+ 시 섀도 부스트
raw.neutralChromaticity?.x = ...   // WB 화이트 포인트 미세조정
```

---

## 📋 권장 순서

1. **Fix A (진단 로깅)** — 먼저 배포해서 실제 회전 발생 조건 로그 수집
2. **Fix B (enforceAspect 조건화)** — 데이터 보고 판단
3. **Fix C (baseline 색감)** — 기본 옵션으로 추가 (토글 가능)
4. **Fix D (boostAmount 노출)** — 고급 사용자용 UI

## 🎯 RAW 엔진 전체 재작성 (`raw-metal-engine` 브랜치)

이미 별도 브랜치에 **libraw + Metal compute kernel** 기반 RAW 엔진 WIP 상태로 존재:
- libraw 네이티브 디코드 (Apple RAW 보다 더 많은 카메라 지원)
- Metal develop_process 커널로 exposure/WB/contrast 일괄 GPU 처리
- 20-30ms per 5616×3744 (50fps) — 현 CIRAWFilter 대비 **10배+ 빠름**

**머지 고려사항**:
- libraw LGPL 라이선스 + 동적 링크 규약
- dylib 번들링 (bundle_libraw.sh 스크립트 있음)
- Metal 셰이더 + 빌드 시스템 설정

머지 시 현재 브랜치의 안정성 vs raw-metal-engine 의 성능/유연성 트레이드오프 검토 필요.
