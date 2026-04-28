# PickShot 심층 분석 보고서 (2026-04-21)

**분석 시점**: 2026-04-21 오전 (예정 3 AM → 실제 8 AM, 세션 종료로 지연)
**브랜치**: `feature/list-view-nstableview`
**기준 태그**: `v8.7-stable`

---

## 🎯 요약

PickShot 은 이미 **Apple Silicon 네이티브 최적화 상당 수준** 도달. Metal/ANE/VideoToolbox 모두 적극 활용 중. 남은 개선은 "없는 것 추가" 보다 "있는 것 더 잘 쓰기" 방향.

---

## 1. Metal 활용 현황

### ✅ 이미 통합됨 (`MetalImageProcessor.swift`)
| 기능 | 기술 | 사용 위치 |
|---|---|---|
| 리사이즈 | MPS Lanczos | 썸네일/프리뷰 축소 |
| 히스토그램 | MPSImageHistogram (256-bin) | `HistogramView`, `ImageAnalysisService`, `ImageCorrectionService` |
| 톤 커브 | CIColorControls + Metal CIContext | 밝기/콘트라스트/감마 |
| IOSurface | 제로카피 GPU 메모리 | 디스플레이용 (활용 여지 있음) |
| 라플라시안 선명도 | Accelerate vDSP | CPU, `ImageAnalysisService` |

### 🆕 본 세션 추가
**실시간 히스토그램** (이번 커밋):
- `HistogramOverlay` 에 `liveImage: NSImage?` 파라미터 추가
- `developedImage` 변화 → 50ms 디바운스 재계산 (20fps 상한)
- Metal GPU 히스토그램 호출 → 슬라이더 드래그 중 반영
- 기존: photo 변경 때만 → 이제: 보정 변경 때마다

### ⏳ 남은 Metal 후보 (우선순위 순)

| 우선순위 | 항목 | 예상 공수 | 체감 효과 |
|---|---|---|---|
| 🥇 | **Loupe 돋보기** Metal sampler | 2-3h | 마우스 hover 지연 0ms |
| 🥈 | **클리핑 오버레이** (Shift+H) | 1-2h | CI 3개 필터 → 1 커널 |
| 🥉 | **커브 에디터** 라이브 프리뷰 (1D LUT) | 3-4h | 드래그 중 60fps |
| 🎯 | **MetalFX Spatial 업스케일** | 4-5h | 저해상도 → 고해상도 즉시 |
| 💎 | **RAW Metal 파이프라인** | 브랜치 완성 | raw-metal-engine 브랜치 머지 |
| 🚀 | **배치 내보내기** Metal | 1-2d | 100장 5분 → 30초 |

---

## 2. AI 엔진 검증

### 현황
| 엔진 | 모델 | 가속 | 상태 |
|---|---|---|---|
| NIMA | 미적 품질 (1-10) | CoreML `.all` (ANE/GPU) | ✅ 정상 |
| AdaFace R18 | 얼굴 임베딩 (512-dim) | CoreML `.all` | ✅ 정상 |
| VNFeaturePrint | 얼굴 특징 (fallback) | Vision + ANE | ✅ |
| VNDetectFace* | 얼굴 좌표 | Vision + ANE | ✅ |
| AIEnhance/Denoise | 보정/노이즈 | CoreML `.all` | ✅ |
| ClaudeVision | 클라우드 분석 | 구독 전용 | 범위 외 |

### 병렬화 패턴
- **AdaFace 추론**: 직렬 (CoreML thread-unsafe) + 얼굴 감지는 `DispatchQueue.concurrentPerform` → **이미 최적**
- 추론 배치화 가능성 있지만 복잡도 대비 효과 미미

### 결론
AI 엔진 자체는 문제 없음. **ANE 강제 CPU** 케이스 없음. 개선 여지:
- Metal 전처리 (크롭/리사이즈/정규화) 를 추론 입력 직전에 GPU 로 처리 → Vision/CoreML 로 전달
- 현재는 CGImage → CIImage → `VNImageRequestHandler` 경로, 중간 CPU 단계 일부 있음

---

## 3. 통합 메모리 아키텍처 (Apple Silicon UMA)

### 현황 — 3층 방어
| 레이어 | 구현 | 용량 / 정책 |
|---|---|---|
| Soft | `MemoryGuardService` | 시스템 RAM × 0.4 — 소프트 경고 |
| Warning | 동 | RAM × 0.6 — Layer 2 트림 (HiRes/Preview 30%) |
| Emergency | 동 | RAM × 0.65 — Layer 3 전체 플러시 |
| OS Pressure | `DispatchSource.memorypressure` | 시스템 신호 자동 반응 |

### 캐시 레이어
| 캐시 | 용량 | 교체 정책 |
|---|---|---|
| ThumbnailCache (NSCache) | 2-20GB tier 기반 | NSCache auto + 메모리압박 시 해제 |
| DiskThumbnailCache | 2GB 기본 / 사용자 설정 | 해시 경로 + JPEG 0.82 |
| PreviewImageCache | 300MB | LRU accessCounter |
| HiResCache (NSCache) | 300MB cost | 사진 전환 시 즉시 purge |
| AggressiveImageCache | RAM tier 기반 (16GB → 200MB) | NSCache + pressure 자동 해제 |

### 잠재 이슈
1. **PreviewImageCache 300MB 하드코드** — 64GB 시스템에서 타이트. RAM 기반 동적 스케일 고려.
2. **IOSurface 제로카피 활용도 제한적** — 현재 MetalImageProcessor.createIOSurface 존재하나 실제 렌더 파이프는 아직 CGImage 중심. MTKView 기반 프리뷰 렌더 전환 시 풀 활용 가능.
3. **대용량 폴더 (10K+) 에서 photos 배열 선형 스캔** — 부분적으로 `_photoIndex` 로 해결됐지만 `filteredPhotos` 가 computed 라 반복 호출 시 비용.

### 권장 조치
- `PreviewImageCache.maxCost` 를 `SystemSpec.shared.ramGB` 기반으로 계산
- MTKView 기반 HiRes 프리뷰 렌더러 (IOSurface 공유) — 2-3일 작업
- `filteredPhotos` 결과 캐싱 + 무효화 훅 (이미 `invalidateFilterCache` 있음 — 추가 호출처 점검)

---

## 4. 미디어 엔진 (VideoToolbox / MetalFX)

### 현재 사용
- **`HWJPEGDecoder`** — VideoToolbox `VTDecompressionSession` 기반 HW JPEG 디코드 (Apple Silicon)
  - Fallback: `CGImageSourceCreateThumbnailAtIndex`
  - 메모리 전략: HW=전체 / SW=mmap (40MB 피크 회피)

### 미활용 기술
| 기술 | 용도 가능성 | 우선순위 |
|---|---|---|
| **MetalFX Spatial** | 저해상도 프리뷰 → 고해상도 업스케일 (Stage1 → Stage2 즉시 전환) | 🥇 |
| **MetalFX Temporal** | 동영상 재생 품질 업 | 🥉 (동영상 편집 아님) |
| **VideoToolbox H.265** | 녹화본 썸네일 가속 | 🥈 |
| **CoreVideo IOSurface 공유** | GPU↔GPU 제로카피 (현재 존재, 활용 미흡) | 🥇 |

### 권장
**MetalFX Spatial 업스케일** 통합이 가장 큰 체감 효과:
- Stage 1 프리뷰(1200-1600px) → Stage 2(3200-4000px) 를 **디스크 재로딩 없이 GPU 업스케일**
- 체감: 사진 전환 시 품질 "튀어오름" → 부드러운 fade

---

## 5. 스트레스 테스트 + 심층 분석

### 발견 사항
| 영역 | 이슈 | 심각도 |
|---|---|---|
| Metal 호출 | `DispatchSemaphore.wait(timeout: 5s)` in MetalImageProcessor | 🟡 메인 스레드 블로킹 가능 (현재 사용 지점들은 백그라운드 큐 → 실질 문제 없음) |
| 동기 디스크 I/O | NSImage(contentsOf:) 여전히 일부 경로 | 🟡 |
| 렌더 파이프 | CGImage ↔ CIImage ↔ NSImage 왕복 | 🟡 (최적 경로 MTKView) |
| @Published | PhotoStore.photos (대용량 배열) | 🟡 (v8.6.2 `_suppressDidSet` 로 완화) |
| SwiftUI Table | 내부 mouse tracking (리스트뷰 한계) | 🔴 → NSTableView 재작성으로 해결 (본 브랜치) |

### UI 요소 검증 (수동 테스트 필요 영역)
- [ ] 2876장 폴더 스크롤 (60fps 유지?)
- [ ] 리스트뷰 ↔ 그리드뷰 전환 시 상태 보존
- [ ] 메모리 48-64GB 시스템에서 피크 사용량 (기대치: 4-6GB)
- [ ] 키보드 반복 이동 시 썸네일 로드 블로킹
- [ ] RAW 파일 10장 동시 미리보기 (탭 간 전환)

---

## 6. 추가 개선 추천

### 단기 (1-2일)
1. **실시간 클리핑 오버레이 Metal 전환** — Shift+H 의 CI 3-필터 체인 → 1 커널
2. **Loupe Metal 화** — MTLTexture 1회 업로드 + sampler 좌표 변경
3. **MetalFX 업스케일 Stage1→Stage2 전환** — 사진 전환 UX 혁신

### 중기 (3-5일)
4. **raw-metal-engine 브랜치 머지 준비** — libraw + Metal RAW 파이프라인 (실RAW 편집 핵심)
5. **NSTableView Stage 3-6 완성 + 메인 머지** — 본 브랜치 Stage 2 후속
6. **MTKView 기반 HiRes 프리뷰** — IOSurface 제로카피 풀 활용

### 장기 (Pro 플랜 대비)
7. **배치 내보내기 Metal 파이프라인** — 100장/30초 (현재 5분)
8. **노이즈 리덕션 NLM / BM3D** — ISO 6400+ 사진 필수
9. **렌즈 프로파일 보정** — 왜곡/비네팅 자동 (lensfun MIT 대체)
10. **전문 색보정 툴 (HSL, 컬러 그레이딩 wheel)** — Capture One 수준

### 운영/품질
11. **자동화된 회귀 테스트 스위트** — 스크롤 60fps 검증, 메모리 누수 감지
12. **사용자 원격 진단** — MemoryLeakTracker 데이터 수집 + 대시보드
13. **Signed dmg + Notarization 자동화** — 현재 `Scripts/resign_for_distribution.sh` 수동

---

## 🏁 결론

PickShot 은 현재 **Bridge/Lightroom 급 네이티브 최적화**를 상당 부분 달성. 가장 큰 남은 기회는:

1. **MetalFX 업스케일** — 사진 전환 UX 혁신적 개선
2. **NSTableView 리스트뷰 완성** (본 브랜치 — Stage 3-6)
3. **raw-metal-engine 브랜치 머지** — RAW 편집 Pro 수준

이 세 개가 완료되면 **v9.0 로 메이저 버전 업** 정당화 가능.

본 세션에서 적용된 것: **실시간 히스토그램** (슬라이더 드래그 중 Metal GPU 히스토그램 재계산).
