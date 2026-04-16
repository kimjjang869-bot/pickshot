# PickShot App Store 제출 가이드

이 문서는 PickShot v8.1.0 을 Mac App Store 에 등록할 때 사용할 메타데이터와 체크리스트입니다. Apple Developer Program 승인 후 App Store Connect 에 그대로 복사해 사용하세요.

## 앱 정보

### 기본 정보
| 항목 | 값 |
|------|-----|
| 앱 이름 | **PickShot** |
| 부제 (Subtitle) | **세상에서 제일 빠른 사진 셀렉** |
| 번들 ID | com.pickshot.app |
| SKU | pickshot-001 |
| 기본 언어 | 한국어 |
| 카테고리 | 사진 및 비디오 |
| 보조 카테고리 | 생산성 |
| 연령 등급 | 4+ |
| 버전 | 8.1.0 |
| 빌드 번호 | 23 |

### 가격 정책
| 구분 | 가격 | Product ID |
|------|------|------------|
| 앱 다운로드 | 무료 (21일 트라이얼 포함) | - |
| Pro 월간 구독 | ₩1,900 | `com.pickshot.pro.monthly` |
| Pro 연간 구독 | ₩15,000 | `com.pickshot.pro.yearly` |

## 앱 설명 (한국어)

### Promotional Text (170자)
```
사진가를 위한 macOS 네이티브 사진 셀렉 도구. Metal GPU 가속 + Apple Vision AI. 10,000장도 망설임 없이.
```

### Description (4000자 이내)
```
PickShot — 세상에서 제일 빠른 사진 셀렉 도구

사진작가의 시간을 1/10 로 줄여주는 macOS 네이티브 컬링(culling) 앱입니다. Metal GPU 가속과 Apple Vision 프레임워크로 10,000장 촬영본도 스트레스 없이 선별하세요.

● 핵심 기능

━ 초고속 뷰잉 ━
• Metal GPU 가속 디코더로 RAW/JPG 즉시 표시
• 하드웨어 JPEG 디코더로 썸네일 로딩 1/10 시간
• 서브샘플링 + NSCache L1 캐시 + 디스크 캐시 2GB
• 화살표키 즉시 반응, 로딩 스피너 없음

━ 스마트 셀렉 ━
• JPG+RAW 자동 매칭 (Canon/Sony/Nikon/Fuji 등)
• 1~5 별점 레이팅, 6개 컬러 라벨 (6~9키)
• 전체화면 컬링 모드 (Cmd+F) + 필름스트립
• 마우스 뒤로/앞으로 버튼 → 폴더 히스토리 이동
• 외부 Finder 드롭 지원

━ 로컬 AI 분석 ━ (모든 처리가 Mac 내부에서 완료)
• 선명도/노출/구도 100점 품질 점수
• 얼굴 감지 + 그룹핑 (Apple Vision)
• 장면 분류 140+ 키워드 (인물/풍경/음식 등)
• 눈감김/흔들림 자동 경고
• 수평/수직 자동 보정 가이드

━ 전문가 도구 ━
• 커스텀 폴더명으로 JPG/RAW 분리 내보내기
• XMP 사이드카 (Lightroom/Bridge 호환)
• 메모리카드 자동 백업 + EXIF 기반 날짜별 정리
• 카메라 테더링 (USB 연결 시 실시간 촬영 전송)
• LUT 실시간 프리뷰 (.cube 파일)
• 비디오 플레이어 + 썸네일 미리보기

━ Google Drive 연동 ━ (선택)
• 클라이언트 내보내기 / G셀렉 기능
• 업로드 → 자동 공유 링크 생성
• drive.file 권한만 사용 (다른 파일 접근 X)

● 구독 안내

무료 평가 기간: 설치 후 21일간 모든 기능 무제한 사용
Pro 월간: ₩1,900 / 월
Pro 연간: ₩15,000 / 년 (34% 할인)

● 기술 요구사항

• macOS 14.0 (Sonoma) 이상
• Apple Silicon 또는 Intel Mac
• 8GB 이상 RAM 권장 (16GB+ 추천)
• 권장 저장공간: 500MB

● 개인정보 보호

PickShot 은 모든 분석을 사용자의 Mac 안에서만 처리합니다. 사진, 레이팅, 얼굴 데이터 등 어떤 정보도 외부 서버로 전송되지 않습니다. Google Drive 연동은 선택 기능이며, 토큰은 macOS Keychain 에만 안전하게 저장됩니다.

● 문의

버그 신고 / 기능 요청: https://github.com/kimjjang869-bot/pickshot/issues
개인정보 처리방침: https://kimjjang869-bot.github.io/pickshot/privacy.html
서비스 약관: https://kimjjang869-bot.github.io/pickshot/terms.html
```

### Keywords (100자 이내, 쉼표 구분)
```
사진,셀렉,셔터,RAW,JPG,컬링,culling,포토,카메라,Vision,Lightroom,사진가,사진선별,메타,EXIF
```

### What's New in This Version (v8.1.0)
```
• App Sandbox 지원 — Mac App Store 등록 준비
• 출시 전 테스터 1년 활성화 키 시스템
• 코드 심층 분석 — 성능 최적화 및 버그 수정
• 출시 전 AI 기능 임시 숨김 (추후 업데이트 예정)
• 21일 무료 평가 기간 + Pro 구독 모델 전환
```

### Support URL
```
https://github.com/kimjjang869-bot/pickshot/issues
```

### Marketing URL
```
https://kimjjang869-bot.github.io/pickshot/
```

### Privacy Policy URL (필수)
```
https://kimjjang869-bot.github.io/pickshot/privacy.html
```

## App Review Information (심사 노트)

### Demo Account
테스터 키 제공:
```
PS-NQA4-U9UA-DJ3P
```
사용법: 앱 실행 → **Cmd+Shift+Option+K** 눌러 키 입력창 → 위 키 입력 → Pro 권한 1년 활성화

### Notes for Reviewer (영문)
```
PickShot is a macOS-native photo culling (selection) app for photographers.

Key points for review:
1. TRIAL & SUBSCRIPTION: The app offers a 21-day free trial with full Pro features. After trial, users see a paywall and can subscribe ($1.99/mo or $15.00/year). IAP products: com.pickshot.pro.monthly, com.pickshot.pro.yearly

2. TESTER KEY FOR REVIEW: To bypass the paywall and access all features without purchase, use this hidden shortcut:
   - Press Cmd+Shift+Option+K
   - Enter key: PS-NQA4-U9UA-DJ3P
   - This grants 1-year Pro access (created specifically for App Review)

3. FILE ACCESS: App requires permission to access user-selected folders (photos/RAW files). This uses standard NSOpenPanel with security-scoped bookmarks per App Sandbox requirements.

4. EXTERNAL DRIVES: App uses temporary-exception entitlement for /Volumes/ to allow macOS system access dialog instead of NSOpenPanel for each disk. This is the standard pattern used by Lightroom, Capture One, etc.

5. GOOGLE DRIVE (OPTIONAL): Optional "Client Select" / "G-Select" feature uses OAuth 2.0 with drive.file scope only (app-created files). Tokens stored in macOS Keychain. Users can logout which triggers server-side token revoke.

6. LOCAL AI: All image analysis (quality scoring, face detection, scene classification) uses Apple Vision framework locally. No data leaves the device.

7. AI FEATURES HIDDEN: Some advanced AI features are temporarily hidden in this release via a feature flag (AppConfig.hideAIFeatures). Core functionality is fully usable without them.

Contact: kimjjang869@gmail.com
```

### Contact Information
| 항목 | 값 |
|------|-----|
| 이름 | 김광호 |
| 이메일 | kimjjang869@gmail.com |
| 전화 | (App Store Connect 에 등록된 개발자 연락처) |

## App Privacy (App Store Connect 개인정보 섹션)

### Data Types Collected
**아무것도 수집하지 않음** (Not Collected)

모든 섹션에서 "Not Collected" 선택:
- Contact Info: Not Collected
- Health & Fitness: Not Collected
- Financial Info: Not Collected
- Location: Not Collected
- Sensitive Info: Not Collected
- Contacts: Not Collected
- User Content: Not Collected (로컬 처리만, 외부 전송 없음)
- Browsing History: Not Collected
- Search History: Not Collected
- Identifiers: Not Collected
- Purchases: App Store 결제만 사용 (Apple 처리)
- Usage Data: Not Collected
- Diagnostics: Not Collected
- Other Data: Not Collected

### Third-Party Data
- **Google Drive (선택)**: 사용자가 명시적으로 로그인할 때만. drive.file scope 로 앱이 생성한 파일에만 접근.
- **GitHub Releases API**: 익명 HTTP 요청으로 업데이트 확인만.

### 요약
"This app does not collect data" 로 신고 가능.

## Screenshot Requirements (최소 요구사항)

### Mac Screenshots (필수)
- 해상도: 1280x800, 1440x900, 2560x1600, 2880x1800 중 택1
- 개수: 최소 1개, 최대 10개
- 형식: PNG 또는 JPG (RGB, 72dpi)

### 권장 스크린샷 구성 (10개)
1. **메인 뷰**: 폴더 브라우저 + 썸네일 그리드 + 프리뷰 (기본 작업 화면)
2. **전체화면 컬링**: Cmd+F 로 전환한 컬링 모드
3. **레이팅/컬러 라벨**: 별점 + 컬러 라벨 적용된 상태
4. **JPG+RAW 매칭**: 매칭된 파일 썸네일 (RAW 배지 표시)
5. **EXIF 정보**: 프리뷰 하단 EXIF 패널
6. **내보내기**: 커스텀 폴더명 설정 화면
7. **비디오 플레이어**: LUT 프리뷰 + 썸네일
8. **메모리카드 백업**: SD카드 감지 + EXIF 기반 폴더 생성
9. **G셀렉 설정**: Google Drive 연동 설정 화면
10. **설정**: 캐시/성능/단축키 설정

### 스크린샷 캡처 방법
```bash
# 1. 앱을 Release 모드로 빌드
xcodebuild -project PhotoRawManager.xcodeproj \
    -scheme PhotoRawManager -configuration Release build

# 2. DerivedData 에서 앱 실행
open ~/Library/Developer/Xcode/DerivedData/PhotoRawManager-*/Build/Products/Release/PickShot.app

# 3. 스크린샷 (Cmd+Shift+4 → Space → 창 클릭, 혹은 Cmd+Shift+3 전체)
# 4. 위 10개 구성으로 촬영
```

## StoreKit — IAP 상품 등록 가이드

App Store Connect → My Apps → PickShot → In-App Purchases

### 1. 구독 그룹 생성
- **이름**: Pro
- **Reference Name**: pickshot-pro

### 2. 월간 구독 추가
- Product ID: `com.pickshot.pro.monthly`
- Reference Name: Pro Monthly
- Duration: 1 Month
- Price: Tier 2 (₩1,900) — App Store Connect 에서 선택
- Display Name (KR): Pro 월간
- Description (KR): "모든 기능을 월간으로 이용하세요. 언제든 취소 가능합니다."
- Display Name (EN): Pro Monthly
- Description (EN): "Unlock all features with a monthly subscription. Cancel anytime."

### 3. 연간 구독 추가
- Product ID: `com.pickshot.pro.yearly`
- Reference Name: Pro Yearly
- Duration: 1 Year
- Price: ₩15,000
- Display Name (KR): Pro 연간
- Description (KR): "34% 할인된 연간 구독으로 Pro 기능 이용. 언제든 취소 가능합니다."
- Display Name (EN): Pro Yearly
- Description (EN): "Save 34% with yearly subscription. Cancel anytime."

### 4. 구독 혜택 설명 (두 상품 공통)
```
Pro 구독 혜택:
• 모든 기능 무제한 사용
• 향후 AI 기능 우선 이용
• 클라이언트 내보내기 / G셀렉
• 우선 기술 지원
```

## 제출 전 체크리스트

### 코드
- [x] v8.1.0 (Build 23) MARKETING_VERSION 설정
- [x] App Sandbox 활성화
- [x] Entitlements 파일 완성
- [x] Release 빌드 성공
- [x] 코드 서명 (Apple Development 인증서)
- [ ] Distribution 인증서로 서명 (Apple Developer 승인 후)
- [ ] Notarization 통과 (Archive + Upload 시 자동)

### 메타데이터
- [x] 앱 설명 작성
- [x] 키워드 작성
- [x] Privacy Policy URL 배포
- [x] Terms of Service URL 배포
- [x] Support URL 확인
- [x] 심사 노트 작성
- [x] 테스터 키 준비
- [ ] 스크린샷 10장 준비 (수동 작업 필요)
- [ ] 앱 아이콘 1024x1024 준비

### App Store Connect
- [ ] Apple Developer Program 승인 대기 중
- [ ] 앱 등록 (Bundle ID com.pickshot.app)
- [ ] IAP 상품 2개 등록 (monthly/yearly)
- [ ] 앱 정보 입력
- [ ] 스크린샷 업로드
- [ ] 심사 노트 입력
- [ ] Archive 빌드 업로드
- [ ] 심사 제출

### Google OAuth (완료)
- [x] 브랜딩 정보 등록
- [x] Production 전환
- [x] drive.file scope 확인

## 예상 일정

| 단계 | 소요 시간 |
|------|---------|
| Apple Developer 승인 | 24~48시간 (결제 후) |
| Archive + Upload | 30분 |
| Notarization | 5~30분 |
| 심사 | 24~48시간 (보통 빠름) |
| 출시 | 심사 통과 즉시 |

**총 예상 기간: 승인 후 2~3일 이내 출시 가능**
