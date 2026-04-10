# AI Smart Cull (AI 스마트 셀렉) Design Spec

## Overview
PickShot에 사용자 학습형 AI 셀렉 시스템 추가. 100% 로컬 (Apple Vision + CoreML), 무료, 오프라인 동작.

## Target Scenarios
- 스튜디오 착장 촬영 (400장, 40컷 x 10착장)
- 웨딩/행사 (500~2000장)
- 프로필/증명사진 (50~100장)
- 범용 — 모든 촬영 시나리오

## Architecture

```
SmartCullService.swift (새 서비스)
├── GroupEngine      — 유사 사진 그룹핑
├── QualityScorer    — C컷 자동 탈락
├── StyleLearner     — 사용자 스타일 학습 (폴더별 + 누적)
└── Recommender      — A컷 추천 (품질 x 스타일 유사도)

StyleOnboardingView.swift (새 뷰)
└── 온보딩 스타일 퀴즈 (6단계, 각 9장 AI 이미지)

SmartCullView.swift (새 뷰)
└── AI 셀렉 UI (그룹 표시 + 추천 + 학습 적용)
```

## 1. GroupEngine — 유사 사진 그룹핑

### 방법
1. **시간 기반 1차 분리**: EXIF 촬영시간 5분+ 간격 → 새 그룹 (착장 변경)
2. **VNFeaturePrintObservation 2차 클러스터링**: 그룹 내 유사 사진 묶기
   - 이미지 800px 축소 → VNGenerateImageFeaturePrintRequest
   - featurePrint.computeDistance → 유사도 0~1
   - threshold 0.5 이하 → 같은 클러스터

### 속도
- 400장: ~15초 (병렬 4코어)
- 2000장: ~60초

## 2. QualityScorer — C컷 자동 탈락

### 기존 ImageAnalysisService 활용
- 흔들림 감지 (Laplacian sharpness)
- 눈감김 (VNDetectFaceLandmarks)
- 초점 미스 (얼굴 영역 선명도)
- 노출 이상 (히스토그램 분석)

### 점수
- 100점 만점: 선명도(40%) + 노출(30%) + 구도(30%) - 이슈 감점
- 30점 미만 → C컷 자동 표시 (회색 + 취소선)

## 3. StyleLearner — 사용자 스타일 학습

### 3.1 온보딩 스타일 퀴즈 (첫 실행)

6단계, 각 9장 AI 생성 이미지 (앱 번들 내장, ~11MB):

| Step | 카테고리 | 학습 목표 |
|------|---------|----------|
| 1 | 서있는 포즈 | 전신 구도 선호 |
| 2 | 앉아있는 포즈 | 반신 구도 선호 |
| 3 | 얼굴 클로즈업 | 표정/시선 선호 |
| 4 | 그룹 사진 | 인원 배치 선호 |
| 5 | 조명/톤 | 밝기/대비 선호 |
| 6 | 컬러/분위기 | 색온도/스타일 선호 |

각 단계에서 사용자가 3~4장 선택 → VNFeaturePrint로 특징 벡터 추출 → 선호 벡터 프로필 구축

### 3.2 폴더별 학습

사용자가 현재 폴더에서 수동 셀렉 (별점/SP) → 선택/탈락 패턴 즉시 분석:
- 선택된 사진의 특징 벡터 평균 → "선호 벡터"
- 탈락 사진의 특징 벡터 평균 → "비선호 벡터"
- 코사인 유사도로 나머지 사진 점수 매기기

### 3.3 누적 학습

모든 셀렉 기록 저장 → 시간이 지날수록 정확해짐:
- 저장: `~/.pickshot/style_profile.json`
- 구조: `{ selectedVectors: [...], rejectedVectors: [...], sessionCount: N }`
- 가중 평균: 최근 세션 가중치 높게 (시간 decay)

## 4. Recommender — A컷 추천

### 최종 점수 공식
```
finalScore = qualityScore * 0.4 + styleScore * 0.4 + diversityBonus * 0.2
```

- **qualityScore**: ImageAnalysisService 품질 점수 (0~100)
- **styleScore**: 사용자 선호 벡터와의 코사인 유사도 (0~100)
- **diversityBonus**: 같은 클러스터에서 이미 선택된 것이 없으면 보너스

### 적용
- 각 클러스터에서 최고 점수 → 별점 5 + 컬러레이블 녹색
- 상위 30% → 별점 3~4
- 하위 30% → C컷 (별점 0)

## 5. UI Flow

### 메인 버튼
툴바 "AI 분류" 드롭다운 메뉴에 "AI 스마트 셀렉" 추가

### SmartCullView (시트)
```
┌─────────────────────────────────┐
│  AI 스마트 셀렉                   │
│                                  │
│  [1단계] 유사 그룹핑 중... ████░ 75% │
│  [2단계] 품질 분석 중...           │
│  [3단계] 추천 대기                 │
│                                  │
│  ○ 학습 데이터: 3세션 누적         │
│  ○ 온보딩 완료: ✓                │
│                                  │
│  [시작]  [설정]  [닫기]           │
└─────────────────────────────────┘
```

### 결과 적용 후
- 썸네일 그리드에 그룹 구분선 표시
- C컷: 반투명 + ❌ 오버레이
- A컷 추천: ⭐ 오버레이 + 녹색 테두리
- 사용자가 조정 → "학습 적용" 버튼 → 패턴 업데이트

## 6. Data Storage

| 데이터 | 위치 | 크기 |
|--------|------|------|
| 온보딩 이미지 (54장) | 앱 번들 Assets | ~11MB |
| FeaturePrint 벡터 | 메모리 (폴더별) | ~2MB/1000장 |
| 스타일 프로필 | `~/.pickshot/style_profile.json` | ~100KB |
| 세션 기록 | `~/.pickshot/cull_sessions/` | ~50KB/세션 |

## 7. Performance Targets

| 단계 | 400장 | 2000장 |
|------|-------|--------|
| 그룹핑 | ~15초 | ~60초 |
| C컷 탈락 | ~20초 | ~90초 |
| 학습 적용 | ~5초 | ~20초 |
| **총** | **~40초** | **~3분** |

## 8. Dependencies
- Apple Vision framework (VNFeaturePrintObservation, VNDetectFaceLandmarks)
- 기존 ImageAnalysisService (품질 분석)
- CoreML (향후 on-device fine-tuning)

## 9. Implementation Order
1. GroupEngine (VNFeaturePrint 기반 그룹핑)
2. QualityScorer (기존 서비스 연결)
3. Recommender (점수 계산 + 적용)
4. SmartCullView (UI)
5. StyleOnboardingView (온보딩 퀴즈)
6. StyleLearner (누적 학습)
