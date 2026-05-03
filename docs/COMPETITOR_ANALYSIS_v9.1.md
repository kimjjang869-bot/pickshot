# PickShot v9.1.0 경쟁자 심층 비교 분석

> **작성일**: 2026-05-03  
> **분석 환경**: macOS Sequoia / Apple Silicon  
> **분석자**: Claude (deep-research)  
> **출처**: 각 앱 공식 사이트, Mac App Store, Petapixel, Fstoppers, Photographylife, FilterPixel 벤치마크, Aftershoot 비교 블로그, Adobe 공식 포럼, Lightroom Queen, DPReview, Reddit r/photography  
> **신뢰도**: 가격/평점은 2026년 5월 직접 조회 / 속도 수치는 2025–2026 발표된 공개 벤치마크 인용

---

## Executive Summary

| 항목 | 결론 |
|---|---|
| **PickShot 가장 가까운 경쟁자** | **Photo Mechanic 6** (속도 + 메뉴얼 컬링 철학), **RAW Power** (Mac 네이티브, ex-Aperture 정신) |
| **PickShot 명백한 우위** | (1) Apple Silicon + Vision 프레임워크 풀 활용 (2) 17,000장 ARW 부드러운 키 네비 (3) macOS 13+ 네이티브 SwiftUI/Metal — 비슷한 속도이지만 더 현대적 UI |
| **PickShot 명백한 약점** | (1) 인지도 0 vs Photo Mechanic 20년+ 시장 (2) AI 컬링 범용성에서 Aftershoot/Narrative 미달 (3) Windows 미지원 |
| **차별화 포인트 1** | **"빠른 메뉴얼 컬링 + Apple 네이티브 + Pro AI 보조"** 의 교차점 — 현재 시장에 명확한 빈자리 |
| **차별화 포인트 2** | 7일 무료 + Pro 구독 모델은 합리적이지만, **일회성 라이선스 옵션**도 있어야 Photo Mechanic 이탈 유저 흡수 가능 |

---

## 1. 종합 비교표

| 앱 | 카테고리 | 속도 (1000장) | AI 컬링 | macOS 네이티브 | 가격 (USD) | App Store | 비고 |
|---|---|---|---|---|---|---|---|
| **PickShot v9.1.0** | 컬링 + 뷰어 | 17,000장 부드러움 (M4 Max) | 얼굴/흔들림/노출/장면 | ✅ Swift/Metal/Vision | 7일 무료 + Pro 구독 | ❌ 미상장 | 이번 분석 기준 |
| **Photo Mechanic 6** | 컬링 표준 | < 10분 (메뉴얼) | ❌ 없음 | ⚠️ 일부 (X11 잔재) | $14.99/mo, $149/yr, $299 평생 | ❌ 미상장 | 20년+ 시장 표준 |
| **FastRawViewer** | RAW 뷰어 | 즉시 (임베디드 JPEG) | ❌ 없음 | ✅ Apple Silicon | $23.99 일회성 | ❌ 미상장 | LibRaw 팀 제작 |
| **Lightroom Classic** | 풀 파이프라인 | 60–90분 (메뉴얼) | 부분 (Adaptive Subject) | ⚠️ Electron-ish | $9.99/mo (Photography) | ❌ 미상장 | 디팩토 표준 |
| **Narrative Select** | AI 컬링 | 18분 | ✅ 얼굴/표정/포커스 | ✅ Mac 네이티브 | $10–$60/mo (구독만) | ❌ 미상장 | 30일 무료 체험 |
| **Aftershoot** | AI 자동 컬링 | 8–12분 | ✅ 흔들림/눈감김/중복 | ✅ Mac 지원 | $10–$60/mo | ❌ 미상장 | "Autopilot" 철학 |
| **RAW Power** | Mac 컬링/편집 | (미공개) | ❌ 없음 | ✅ Apple 정통 | **$39.99 일회성** | ✅ 평점 부족 | ex-Aperture 팀 |
| **ApolloOne** | RAW 뷰어 | 26MP HEIF 32장/초 | ❌ 없음 | ✅ HDR/EDR 지원 | 무료 + IAP ($35.99/$59.99) | ✅ 평점 부족 | HDR 뷰어 강점 |
| **Darkroom 7** | 편집 + 컬링 | (편집 위주) | ❌ 없음 | ✅ iOS/iPadOS/macOS | 무료 + IAP ($9.99/mo, $39.99/yr, $99.99 일회성) | ✅ **4.8★ (29,000+ 리뷰)** | 컬링은 보조 |
| **Apple Photos** | 기본 사진 앱 | 30초+ (RAW 부진) | 일부 | ✅ Apple 기본 | 무료 (OS 포함) | N/A | iCloud 통합 |
| **OptiCull** | AI 컬링 (App Store) | 미공개 | ✅ Magi-Cull (얼굴/흔들림) | ✅ Mac App Store | 14일 무료 + $9.99/mo, $96/yr, $79.99 일회성 | ✅ 평점 부족 | 신규 앱 (2024+) |

---

## 2. 카테고리별 분석

### A. 메뉴얼 컬링 강자 (속도 우선)

#### **Photo Mechanic 6** — 시장 표준, 20년+
- **속도 핵심**: RAW 파일 안의 임베디드 JPEG 미리보기를 사용 → 디코드 비용 0. 1,000장 폴더가 "수 초" 안에 로드됨 ([SLR Lounge](https://www.slrlounge.com/how-to-speed-up-your-workflow-in-lightroom-with-photo-mechanic-6/))
- **벤치마크**:
  - 1,000장 컬링 ~10분 ([Improve Photography](https://improvephotography.com/35288/how-to-use-photomechanic-to-speed-up-lightroom-culling/))
  - 3,500장 컬링 30분 (Lightroom 동일 작업 = 3시간) ([Trung Hoang Photography](https://www.trunghoangphotography.com/for-photographers/photo-mechanic-lightroom-workflow-culling-faster-with-photo-mechanic))
  - 30장 스킴 8초, 전혀 lag 없음 ([Lens Lounge](https://thelenslounge.com/how-to-cull-photos-in-lightroom/))
- **강점**:
  - 사진기자 / 웨딩 / 스포츠 분야 디팩토 표준
  - 메타데이터 (IPTC, FTP 업로드) 강력
  - 50MB+ RAW 도 부담 없음
- **약점**:
  - 인터페이스 dated (X11 잔재) — 사용자들도 "기능 완벽하니 봐줌"으로 평가 ([Capterra](https://www.capterra.com/p/210470/Photo-Mechanic/reviews/))
  - **AI 컬링 일절 없음** — 모든 결정 메뉴얼
  - PM 6 초기 버전 버그 보고 → PM 5 잔류 사용자 존재
  - 가격 인상 (구독 모델 도입) 에 사용자 반발 ([BCG Forums](https://bcgforums.com/threads/camerabits-gives-way-to-subscription-sirens-for-its-photo-mechanic-software.33972/))
- **가격**: 월 $14.99 / 연 $149 / 평생 $299 (Plus 는 +$10/mo) ([공식](https://home.camerabits.com/get-photomechanic/))

#### **FastRawViewer** — RAW 데이터 뷰어 특화
- **속도 핵심**: GPU 가속 + 임베디드 JPEG → 메모리 카드에서 직접 보기 가능 ([공식](https://www.fastrawviewer.com/))
- **강점**:
  - LibRaw 팀 제작 (RAW 디코딩 권위) — 모든 카메라 지원
  - Apple Silicon 네이티브 (M1/M2/M3/M4)
  - 진짜 센서 데이터 표시 (노출 평가용)
- **약점**:
  - **컬링 워크플로우 미완성** — XMP 별점/플래그 정도만
  - 일괄 작업 약함
  - UI 기술적 (사진가용보다 엔지니어용 느낌)
- **가격**: **$23.99 일회성** (30일 무료 체험, 2대 동시 활성화) ([구매 페이지](https://www.fastrawviewer.com/purchase))
- **★ PickShot 인사이트**: 가장 합리적인 가격 모델 — 일회성 라이선스 + 합리적 가격대

---

### B. AI 자동 컬링 (신흥 강자)

#### **Aftershoot** — "Autopilot" 철학
- **속도**: 1,000장 ~9분 (로컬 처리, AI 추론 포함) ([Aftershoot](https://aftershoot.com/blog/aftershoot-vs-photo-mechanic/))
- **AI 능력**:
  - 흔들림, 눈감김, 중복 자동 감지 (30+ 속성 평가)
  - 정확도 91.2% keeper identification ([FilterPixel 벤치마크](https://filterpixel.com/best-photo-culling-software))
  - AI 편집 + 리터칭까지 통합
- **강점**:
  - 밤에 발사하고 아침에 결과 — 진짜 자동화
  - 학습 곡선 낮음
  - 4단계 가격 (Selects $10 → Max $60)
- **약점**:
  - 너무 많이 select (→ 다시 솎아내야)
  - 감정적 뉘앙스 놓침 ("almost-tearful candid" 거부 사례)
  - AI 편집 프로파일은 2,500+ 이미지 학습 필요
- **가격**: $10–$60/mo (4 tiers, 30일 무료) ([Aftershoot Pricing](https://aftershoot.com/blog/aftershoot-pricing-tiers/))

#### **Narrative Select** — "Co-pilot" 철학
- **속도**: 1,000장 18분 (Aftershoot보다 느림)
- **AI 능력**:
  - 얼굴/표정/포커스 분석 (각 인물의 눈감김, 표정 어색함, 미소 분석)
  - Confidence scoring + Close Up Panel (모든 얼굴 표시)
  - **RAW 데이터 직접 렌더링** — "no other AI culling tool in 2026 matches it on this specific metric" ([Narrative Review](https://narrative.so/blog/narrative-review))
- **강점**:
  - 웨딩/포트레이트 특화 — group shots 강력
  - **사용자가 최종 결정** — high-end 포토그래퍼 선호
  - 클린 + 빠른 인터페이스
- **약점**:
  - 풍경/비포트레이트 약함 (얼굴 없으면 무용지물)
  - 구독 only — 평생 라이선스 없음
  - Aftershoot 대비 느림
- **가격**: Lite $10 / Standard $20 / Premium $40 / Ultra $60 — 모두 월 구독 ([Narrative Pricing](https://narrative.so/pricing))

---

### C. 풀 파이프라인 (편집까지)

#### **Adobe Lightroom Classic**
- **속도**: 60–90분 / 1,000장 컬링 (메뉴얼). M4 Pro/Max 기준에서도 미리보기 생성은 CPU bound — Photo Mechanic 대비 한참 느림
- **강점**:
  - 디팩토 표준 — 카탈로그, RAW 현상, 출력까지 한 앱
  - Adaptive Subject mask 등 부분 AI
  - 모든 카메라 RAW 지원
- **약점**:
  - **컬링 자체가 느림** — 미리보기 생성 시간 누적
  - 16GB+ RAM 권장, 8GB는 디스크 스왑 3.2배 ([Filterpixel](https://filterpixel.com/blog/ultimate-guide-to-lightroom-system-requirements))
  - 구독 강제, 영구 라이선스 없음
- **가격**: Adobe Photography Plan $9.99/mo (Lightroom + Classic + Photoshop)
- **★ 인사이트**: 99% 사진가가 라이트룸 사용 → Photo Mechanic + Lightroom 워크플로우가 표준. **PickShot 도 같은 자리 노릴 수 있음 (앞단 컬링 + Lightroom 익스포트)**

---

### D. Mac App Store 컬링/뷰어 5종

#### **RAW Power** ⭐ PickShot에 가장 가까운 철학
- **개발자**: Nik Bhatt (전 Apple Aperture 팀) — "spiritual successor to Aperture"
- **가격**: **$39.99 일회성** (구독 없음)
- **App Store 평점**: 부족 (수치 미표시)
- **강점**: macOS 정통 통합 (Photos, Finder), Apple RAW 엔진 활용, 비파괴 편집
- **약점**: 평점 데이터 부족, 한정된 사용자층, AI 컬링 없음
- **최신 버전**: 3.5.5 (2025-01-15) — Sony A7 V, Fujifilm M-RAW 추가
- **링크**: [App Store](https://apps.apple.com/us/app/raw-power/id1157116444?mt=12)

#### **ApolloOne** — HDR/RAW 뷰어 특화
- **가격**: 무료 + IAP — Standard $35.99 평생 / Pro $59.99 평생 / 월·연 구독 옵션
- **App Store 평점**: 부족
- **강점**:
  - "세계 최초 고속 HDR RAW 뷰어"
  - XDR/EDR 디스플레이 풀 활용
  - 26MP HEIF **32장/초** 처리
  - JPEG XL, AVIF 내보내기
- **약점**: NAS HEIC 작업 시 5–10초 지연, UI 일관성 부족
- **★ 인사이트**: PickShot HDR 워크플로우 추가 시 ApolloOne 과 직접 경쟁 가능
- **링크**: [App Store](https://apps.apple.com/us/app/apolloone-photo-video-viewer/id1044484672)

#### **Darkroom 7** — 편집 + 가벼운 컬링
- **가격**: 무료 + IAP — 월 $9.99 / 연 $39.99 / 평생 $99.99
- **App Store 평점**: **4.8★ / 29,000+ 리뷰** — Editor's Choice
- **강점**:
  - Mac/iPhone/iPad/Vision Pro 통합
  - "Flag & Reject" 컬링 기능
  - Bloom/Halation 등 신규 도구
  - 빠른 로딩
- **약점**:
  - 컬링은 보조 기능 (편집 위주)
  - 대용량 배치 편집 시 크래시 보고
  - macOS 15.4+ 필수
- **링크**: [App Store](https://apps.apple.com/us/app/darkroom-photo-video-editor/id953286746)
- **★ 인사이트**: 평점/리뷰 수 압도적 — Mac App Store 에서 신뢰 쌓는 데 시간 걸림

#### **Apple Photos** (기본 앱)
- **가격**: 무료 (OS 포함)
- **강점**:
  - iCloud Photo Library 자동 동기화
  - 모든 Mac 기본 설치
- **약점**:
  - **RAW 처리 매우 느림** — 30MB RAW 1장 조정에 10–30초 보고 다수 ([Apple Community](https://discussions.apple.com/thread/8191779))
  - RAW 미리보기 over-sharpened
  - iCloud 동기화 RAW 시 스톨
  - 컬링 워크플로우 부재
- **★ 인사이트**: 일반 사용자는 Photos 시작 → 한계 부딪힘 → 전문 컬링 앱 검색. **PickShot 의 진입점**

#### **OptiCull** — App Store AI 컬링 신규
- **가격**: 14일 무료 + Pro 월 $9.99 / 연 $96 / 평생 $79.99
- **App Store 평점**: 부족
- **강점**:
  - "Magi-Cull" — 흔들림/눈감김 자동 거부
  - 듀플리케이트 자동 그룹핑
  - 얼굴 감정 감지 (custom AI)
  - 컬링 시간 90% 감소 주장
- **약점**:
  - 대용량 시 크래시
  - Apple Photos 통합 부재
  - 평점 부족 — 신규 앱
- **링크**: [App Store](https://apps.apple.com/us/app/opticull-fast-photo-culling/id6448657895)

---

## 3. 가격 모델 비교

| 앱 | 일회성 | 월 구독 | 연 구독 | 무료 체험 |
|---|---|---|---|---|
| **PickShot v9.1.0** | ❌ | (Pro 구독) | (Pro 구독) | **7일** |
| Photo Mechanic 6 | **$299** | $14.99 | $149 | (체험) |
| Photo Mechanic Plus | — | $24.99 | $249 | — |
| FastRawViewer | **$23.99** ★ 최저 | — | — | **30일** |
| Lightroom Classic | ❌ | $9.99 (Photography Plan) | — | 7일 |
| Narrative Select | ❌ | $10–$60 | — | 30일 |
| Aftershoot | ❌ | $10–$60 | — | 30일 |
| RAW Power | **$39.99** ★ Mac 일회성 최저 | — | — | (제한 무료) |
| ApolloOne | $35.99 / $59.99 | (있음) | (있음) | 무료 버전 |
| Darkroom 7 | **$99.99** | $9.99 | $39.99 | 무료 버전 |
| OptiCull | **$79.99** | $9.99 | $96 | **14일** |
| Apple Photos | (무료) | — | — | — |

**관찰**:
- **일회성 라이선스는 사용자 선호** — Photo Mechanic, FastRawViewer, RAW Power 모두 보유
- 구독 only 는 Aftershoot/Narrative 같은 "AI 클라우드 추론" 앱들에 적합
- **PickShot 의 7일 무료는 짧음** — 시장 표준 14–30일 대비 경쟁력 약함

---

## 4. PickShot 차별화 포인트 분석

### ✅ PickShot의 명백한 우위

1. **17,000장 ARW 부드러운 키 네비** (M4 Max 기준 — 실측)
   - Photo Mechanic 도 빠르지만 X11 UI / 비-네이티브
   - PickShot = SwiftUI + Metal + NSCollectionView 네이티브
   - O(1) 인덱스 캐시, 라이트룸식 슬롯 패턴 필름스트립

2. **Apple Vision 프레임워크 풀 활용**
   - 얼굴/눈/표정 감지 (Vision)
   - 흔들림/노출 감지
   - 장면 분류 (140+ 키워드)
   - 자동 수평 보정 (VNDetectHorizonRequest)
   - **로컬 추론** — 클라우드 없음, 프라이버시 우위

3. **macOS 13+ 최신 API**
   - SwiftUI/Metal 네이티브
   - VideoToolbox HW JPEG 디코더
   - IOSurface 공유

4. **통합 디버그 HUD** (Shift+⌘+D)
   - Bridge/Photo Mechanic 에는 없는 투명한 성능 측정
   - 사용자가 직접 진단 가능 — 신뢰감

5. **한국어 사용자 우선 + 빠른 피드백 루프**
   - 12년차 본인 사용 — domain expertise 명확
   - 한국 사진가 시장 (웨딩, 행사) 직접 타겟팅 가능

### ⚠️ PickShot의 약점

1. **인지도 0** — Photo Mechanic 20년, Lightroom 무한, Darkroom 29,000+ 리뷰
2. **AI 컬링이 Aftershoot/Narrative 보다 약함**
   - PickShot AI = 단일 사진 평가 (얼굴/흔들림/노출)
   - Aftershoot AI = 배치 자동 거부 + 듀플리케이트 그룹
3. **Windows 미지원** — Photo Mechanic / FastRawViewer 는 양쪽 지원
4. **App Store 미상장** — 발견성, 결제 편의 부족
5. **무료 체험 7일** — 시장 표준 14–30일 대비 짧음
6. **일회성 라이선스 없음** — Photo Mechanic 이탈자 ($299 평생) 흡수 불리

---

## 5. 시장 포지셔닝 권장

### 🎯 Sweet Spot: "Modern Mac-Native Cull + Pro AI Assist"

현재 시장에 정확히 비어 있는 자리:

| 차원 | 시장 | PickShot 채울 빈자리 |
|---|---|---|
| 속도 (메뉴얼) | Photo Mechanic | ✅ 동급 + 더 현대적 UI |
| Mac 네이티브 | RAW Power | ✅ 더 빠르고 더 현대적 |
| AI 보조 | Narrative (Co-pilot) | ✅ 비슷한 철학 + 일괄 작업 강함 |
| 가격 합리성 | FastRawViewer ($23.99) | ⚠️ 일회성 옵션 추가 필요 |
| 한국 시장 | 거의 모두 영어 only | ✅ 한국어 우선 + 한국 사진가 도메인 지식 |

### 권장 액션 (우선순위)

1. **★ 일회성 라이선스 옵션 추가** — Photo Mechanic 평생 $299 / RAW Power $39.99 사이의 포지션 (예: $79–$99 평생)
2. **무료 체험 7일 → 14–30일** — 사진가가 한 행사 풀 워크플로우 시도할 수 있는 시간
3. **Mac App Store 상장 검토** — 발견성 ↑, 결제 편의 ↑ (수수료 30% 부담은 있음)
4. **한국어 마케팅 콘텐츠 + 영어 영상**:
   - "12년차 커머셜 포토그래퍼가 만든" 스토리 강조
   - YouTube 벤치마크 (PickShot vs Photo Mechanic 1000장 컬링)
   - r/photography, r/wedphotography 진입
5. **AI 컬링 강화 — 하지만 Co-pilot 유지**:
   - 현재 단일 사진 평가 → Aftershoot 식 배치 거부 로직 추가
   - "Pick AI" 버튼 → 의심스러운 셀렉만 자동 제안 (사용자 최종 결정)
6. **Photo Mechanic 호환 import/export** — XMP 별점/색 라벨 → 이탈 사용자 흡수
7. **Lightroom 직접 연동** — "Lightroom 으로 보내기" 한 클릭 → 워크플로우 표준 자리매김

---

## 6. 1,000장 처리 시간 비교 (벤치마크 종합)

| 앱 | 1,000장 처리 시간 | 비고 |
|---|---|---|
| **PickShot** | (실측 필요) | 17,000장 부드러운 네비는 검증됨 — 1,000장 워크플로우 측정 권장 |
| FilterPixel | ~3분 | 클라우드 (cloud upload 시간 별도) |
| Aftershoot | 8–12분 | 로컬 AI |
| **Photo Mechanic 6** | **~10분 (메뉴얼)** | 사용자 컬링 시간 포함 |
| Narrative Select | 18분 | 로컬 AI, 얼굴 분석 정밀 |
| Lightroom Classic (메뉴얼) | 60–90분 | 미리보기 생성 + 메뉴얼 |
| Apple Photos | (적합 X) | RAW 1장 조정만 10–30초 |

**★ 권장**: PickShot 도 동일 데이터셋 (Sony ARW 1,000장) 으로 측정한 공식 벤치마크 영상 / 페이지 만들기. 마케팅 핵심 자산.

---

## 7. App Store 평점/리뷰 요약 (2026-05-03 기준)

| 앱 | 평점 | 리뷰 수 | 신뢰도 | 핵심 평 |
|---|---|---|---|---|
| **Darkroom 7** | **4.8★** | **29,000+** | 매우 높음 | Editor's Choice, 빠르고 아름다움 |
| RAW Power | 데이터 부족 | — | 낮음 | "Aperture 후속작" 칭송 vs UI 비-Mac스러움 비판 |
| ApolloOne | 데이터 부족 | — | 낮음 | "Photo Mechanic 의 현대적 대체" |
| OptiCull | 데이터 부족 | — | 낮음 | 컬링 시간 단축, 일부 크래시 보고 |
| Photo Mechanic | (App Store 미상장) | — | — | Capterra/G2 등 외부 리뷰 우호적 |

**★ 인사이트**: Mac App Store 에서 평점 신뢰는 **Darkroom 만 압도적**. 나머지는 충분히 모이지 않음. 신규 앱들의 도달성 한계.

---

## 8. 결론 — PickShot 의 다음 한 걸음

### 단기 (3개월)
- 일회성 라이선스 추가 ($79–$99 권장)
- 무료 체험 7일 → 21일 연장
- "PickShot vs Photo Mechanic 1,000장 벤치마크" 영상 제작
- 한국 웨딩/행사 사진가 커뮤니티 진입

### 중기 (6개월)
- Mac App Store 심사 제출
- Aftershoot 식 배치 AI 거부 로직 추가 (Co-pilot 유지)
- Photo Mechanic XMP 호환 import (이탈 유저 흡수)
- 영어 마케팅 영상 + Petapixel/Fstoppers 리뷰 요청

### 장기 (1년)
- Windows 포팅 검토 (Swift cross-platform 또는 별도 stack)
- HDR 워크플로우 (ApolloOne 따라잡기)
- Lightroom Classic / Capture One 정식 통합

---

## Sources

- [Photo Mechanic 공식](https://home.camerabits.com/get-photomechanic/) / [Pricing](https://camerabits.freshdesk.com/support/solutions/articles/48001252734-photo-mechanic-pricing-and-information) / [Capterra Reviews](https://www.capterra.com/p/210470/Photo-Mechanic/reviews/)
- [FastRawViewer 공식](https://www.fastrawviewer.com/) / [Purchase](https://www.fastrawviewer.com/purchase) / [Photographylife Review](https://photographylife.com/reviews/fastrawviewer)
- [Narrative Select 공식](https://narrative.so/) / [Pricing](https://narrative.so/pricing) / [Review](https://narrative.so/blog/narrative-review)
- [Aftershoot 공식](https://aftershoot.com/) / [vs Photo Mechanic](https://aftershoot.com/blog/aftershoot-vs-photo-mechanic/) / [Pricing Tiers](https://aftershoot.com/blog/aftershoot-pricing-tiers/)
- [RAW Power Mac App Store](https://apps.apple.com/us/app/raw-power/id1157116444?mt=12)
- [ApolloOne Mac App Store](https://apps.apple.com/us/app/apolloone-photo-video-viewer/id1044484672?mt=12)
- [Darkroom App Store](https://apps.apple.com/us/app/darkroom-photo-video-editor/id953286746)
- [OptiCull App Store](https://apps.apple.com/us/app/opticull-fast-photo-culling/id6448657895?mt=12)
- [FilterPixel 2026 벤치마크](https://filterpixel.com/best-photo-culling-software)
- [Lightroom System Requirements 2026](https://filterpixel.com/blog/ultimate-guide-to-lightroom-system-requirements)
- [Apple Photos RAW 한계 (Apple Community)](https://discussions.apple.com/thread/8191779)
- [Lens Lounge — Lightroom 컬링 가이드](https://thelenslounge.com/how-to-cull-photos-in-lightroom/)
- [SLR Lounge — Photo Mechanic + Lightroom 워크플로우](https://www.slrlounge.com/how-to-speed-up-your-workflow-in-lightroom-with-photo-mechanic-6/)
- [Mastering Lightroom — Photo Mechanic Import](https://mastering-lightroom.com/photo-mechanic-lightroom-workflow/)
- [Adventure Wedding Academy — 2026 컬링 소프트웨어 비교](https://adventureweddingacademy.com/culling-software-for-photographers/)
- [Virtualaia — 7 Ideal Image Selection Tools 2026](https://virtualaia.com/7-ideal-image-selection-tools-for-wedding-photographers-in-2026/)
- [Petapixel — Darkroom 7 리뷰](https://petapixel.com/2025/12/10/darkroom-7-photo-editor-on-mac-iphone-and-ipad-has-been-rebuilt-from-the-ground-up/)
- [Greg Benz Photography — M3 MacBook Pro 사진가 리뷰](https://gregbenzphotography.com/photography-reviews/a-photographers-review-of-the-new-m3-macbook-pro/)

---

## 한계 / 추가 조사 필요

1. **PickShot 자체 1,000장 / 5,000장 벤치마크 미측정** — 다른 앱과 동일 데이터셋 (Sony ARW) 으로 측정 필요
2. **ApolloOne / RAW Power / OptiCull 의 정확한 사용자 수 / 매출 데이터** — 공개 정보 부족
3. **Photo Mechanic Mac App Store 평점** — Mac App Store 상장 안 되어 있음 (외부 사이트 리뷰만 가능)
4. **한국 시장 사진가 컬링 앱 사용 비율** — 공개 통계 없음, 직접 인터뷰 / 설문 필요
