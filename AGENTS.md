# PickShot - Codex 프로젝트 컨텍스트

## 프로젝트 개요
PickShot은 macOS 네이티브 사진 선별(culling) 도구. Swift/SwiftUI + Metal + Vision 프레임워크.
**핵심 가치: 세상에서 제일 빠른 뷰잉 + 쉬운 UI**

## 개발자 작업 스타일
- 코드를 단순하게. 복잡하면 메모리 문제 발생
- 기능 많이 추가/수정 시 **에이전트를 나눠서 병렬 처리**
- 한국어로 대화

## 현재 버전: v3.6
GitHub: https://github.com/kimjjang869-bot/pickshot
릴리즈: v3.6 DMG 업로드됨

## 아키텍처

### 주요 파일 구조
```
PhotoRawManager/
├── Models/
│   ├── PhotoItem.swift          # 사진 모델 (25개 필드, QualityAnalysis 포함)
│   └── PhotoStore.swift         # 핵심 상태 관리 (@Published 61개)
├── Services/
│   ├── ImageAnalysisService.swift   # 품질분석, 흔들림/노출/눈감김/포커스 감지
│   ├── ImageCorrectionService.swift # 자동보정 (Apple autoAdjustmentFilters + Vision 수평감지)
│   ├── FaceGroupingService.swift    # 얼굴 그룹핑 (Vision VNDetectFaceRectanglesRequest)
│   ├── AcceleratedImageEngine.swift # 장면분류 (VNClassifyImageRequest), GPU 처리
│   ├── HardwareAcceleration.swift   # VideoToolbox HW JPEG 디코더, Metal, IOSurface
│   ├── GoogleDriveService.swift     # Google Drive 업로드 (OAuth는 Secrets.xcconfig에서 로드)
│   ├── UpdateService.swift          # GitHub Releases 기반 자동 업데이트 체크
│   ├── TetherService.swift          # USB 카메라 테더링
│   ├── ExifService.swift            # EXIF 추출 (캐시 + 쓰레딩 안전)
│   ├── FileCopyService.swift        # 내보내기 (커스텀 폴더명 지원)
│   ├── FileMatchingService.swift    # JPG+RAW 매칭 + 파일 사이즈 로딩
│   └── DiskThumbnailCache.swift     # 디스크 캐시 2GB
├── Views/
│   ├── ContentView.swift            # 메인 뷰 (393줄, 분할됨)
│   ├── ContentView+Toolbar.swift    # 툴바/메뉴 (756줄)
│   ├── ContentView+FolderBrowser.swift  # 폴더 브라우저 (1056줄)
│   ├── ContentView+SupportingViews.swift # 보조 뷰들 (1711줄)
│   ├── PhotoPreviewView.swift       # 사진 프리뷰 (PreviewViewState 분리됨)
│   ├── ThumbnailGridView.swift      # 썸네일 그리드 (NSCache L1 + LRU)
│   └── ExportView.swift             # 내보내기 (폴더명 커스텀)
```

### 시크릿 관리
- `Secrets.xcconfig` (프로젝트 루트, .gitignore에 포함)
- Google OAuth Client ID/Secret 저장
- `GoogleDriveService.loadSecretsFromConfig()`에서 런타임 로드
- **절대 git에 커밋하지 말 것**

## v3.6에서 수행한 주요 작업

### Apple Vision 프레임워크 도입
- `VNDetectHorizonRequest` → 수평 보정 (ImageCorrectionService)
- `VNDetectFaceLandmarksRequest Revision3` → 얼굴/눈 감지 개선
- `VNClassifyImageRequest` → 장면분류 로컬 처리 (140+ 키워드 매핑)
- `VNGenerateAttentionBasedSaliencyImageRequest` → 구도 점수
- `VNGeneratePersonSegmentationRequest` → 인물 세그멘테이션
- `CIImage.autoAdjustmentFilters()` → 자동 색보정

### 얼굴 감지 개선
- 해상도: 640→1280px
- 최소 얼굴 크기: 3%→1%
- 비교 쌍 제한: 2000→5000
- 신뢰도 필터: confidence > 0.5
- 눈감김 임계값: 0.12→0.18
- 포커스 임계값: 15→30

### 장면 분류 개선
- Dictionary 기반 정확 매칭 (contains → 단어 단위)
- 신뢰도 0.25→0.3
- 얼굴 크기 기반 인물/클로즈업 판정
- 미분류 시 "기타" 대신 nil (태그 미부여)

### 품질 시스템 단순화
- 5단계→3단계 (좋음/보통/문제)
- 100점 만점 단일 점수: 선명도(40%) + 노출(30%) + 구도(30%) - 이슈감점
- AI Pick: 75점 이상 + bad 이슈 없음

### 성능 최적화
- 썸네일 NSCache L1 메모리 캐시 (100MB)
- LRU 정상화 (accessOrder 추적)
- 메모리 압박 대응 (.warning→50% 축소, .critical→전체 해제)
- 배열 복사 제거 (6개 함수 직접 인덱스 수정)
- filteredPhotos 단일 for 루프 (10+ 중간 배열 제거)
- PhotoPreviewView @State 31→15개 (PreviewViewState @StateObject 분리)
- ContentView 3905→393줄 (3개 extension 파일로 분할)

### 버그 수정
- ExifService 쓰레딩 lock/unlock 레이스 컨디션
- TetherService didDownloadFile 이중 처리
- AcceleratedImageEngine 데드코드 7개 삭제 (423→259줄)
- Logger .general 카테고리 추가
- AIVisionService 문자열 검색→skipToneCurve 플래그

### 기타
- 내보내기 폴더명 커스텀 (JPG/RAW → 자유 설정)
- 폴더 용량 표시 (FileMatchingService에서 파일 사이즈 로딩)
- UpdateService: GitHub Releases API 방식
- OAuth 시크릿 코드에서 제거 → Secrets.xcconfig

## 시스템 점수 (v3.6 기준, 100점 만점)
- 이미지 디코딩: 95 (HW JPEG, 서브샘플링)
- Metal/GPU: 88
- AI/Vision: 85
- 동시성: 82
- 썸네일 캐시: 85 (NSCache 추가 후)
- 메모리 관리: 75
- SwiftUI 반응성: 78 (배열복사 제거 후)
- 뷰 아키텍처: 75 (분할 후)
- **종합: ~85**

## 다음 로드맵 (FEATURE_ROADMAP.md 참조)

### v3.5→v4.0 예정
1. RAW to JPG 배치 내보내기 + 리사이즈
2. 텍스트/이미지 워터마크
3. 얼굴 이름 태깅
4. 포커스 피킹 오버레이
5. 과노출/저노출 얼룩말 경고
6. 역지오코딩
7. 스마트 컬렉션/저장 필터

## 업데이트 배포 방법
1. 새 버전 빌드 → DMG 생성
2. git commit + push
3. "업데이트 업로드" 라고 하면 GitHub Release 생성 + DMG 첨부
   - curl로 GitHub API 호출 (gh CLI 미설치)
   - 토큰은 git remote URL에 포함됨

## 빌드
```bash
xcodebuild -project PhotoRawManager.xcodeproj -scheme PhotoRawManager -configuration Debug build
```
