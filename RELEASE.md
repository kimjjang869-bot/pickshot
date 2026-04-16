# PickShot v8.1.0 출시 체크리스트

Apple Developer Program 승인을 기다리는 동안 이 문서로 출시 준비 상태를 점검하세요.

## 현재 상태

### 완료 ✅
- [x] App Sandbox 전면 호환 (entitlements, 6개 Process() 제거, Security-Scoped Bookmarks)
- [x] Keychain entitlement 추가
- [x] /Volumes/ temporary-exception (macOS 시스템 권한 대화상자)
- [x] 테스터 1년 활성화 키 시스템 (Cmd+Shift+Option+K)
- [x] 20개 테스터 키 생성 (TESTER_KEYS.md, .gitignore)
- [x] AI 기능 임시 숨김 (AppConfig.hideAIFeatures flag)
- [x] 21일 트라이얼 → Paywall (App Store 정책 준수, 강제 종료 없음)
- [x] Google OAuth 정식 출시 (Production 단계)
  - [x] 브랜딩 정보 등록 (앱명, 홈페이지, 개인정보, 약관)
  - [x] drive.file scope 확인 (non-sensitive, 심사 면제)
  - [x] 서버측 토큰 revoke API 구현
  - [x] 연동 해제 확인 대화상자
- [x] 개인정보 처리방침 + 서비스 약관 페이지 배포
  - https://kimjjang869-bot.github.io/pickshot/privacy.html
  - https://kimjjang869-bot.github.io/pickshot/terms.html
- [x] 앱 내 법적 링크 (About + GSelect 설정)
- [x] Release 빌드 성공 (macOS 14+, Apple Silicon + Intel)

### 대기 ⏳
- [ ] Apple Developer Program 승인 (결제 완료, 24~48시간 대기)

### Apple Developer 승인 후 ⏭️
- [ ] Xcode Signing 에서 **Personal Team → 승인된 Developer Team** 으로 변경
- [ ] Provisioning Profile 자동 재생성 확인
- [ ] App Store Connect 에 앱 등록 (Bundle ID: com.pickshot.app)
- [ ] IAP 상품 2개 등록
  - [ ] `com.pickshot.pro.monthly` — ₩1,900
  - [ ] `com.pickshot.pro.yearly` — ₩15,000
- [ ] **스크린샷 10장 촬영** (가이드: `docs/APP_STORE_SUBMISSION.md`)
  - [ ] `scripts/prepare_screenshots.sh` 로 리사이즈
- [ ] **앱 아이콘 1024×1024 확인** (Assets.xcassets 에 이미 있어야 함)
- [ ] App Store Connect 앱 정보 입력
  - [ ] 앱 설명 (한국어, `docs/APP_STORE_SUBMISSION.md` 복사)
  - [ ] 키워드 입력
  - [ ] 개인정보 처리방침 URL 입력
  - [ ] 카테고리 선택 (사진 및 비디오)
  - [ ] 연령 등급 설정 (4+)
- [ ] **심사 노트 입력** (`docs/APP_STORE_SUBMISSION.md` 의 Notes for Reviewer 복사)
  - [ ] 테스터 키 PS-NQA4-U9UA-DJ3P 안내 포함
- [ ] Xcode 에서 **Product → Archive** 실행
- [ ] **Organizer → Distribute App → App Store Connect** 업로드
- [ ] Notarization 자동 통과 확인
- [ ] App Store Connect 에서 업로드된 빌드 선택
- [ ] 심사 제출
- [ ] 심사 통과 후 출시

## 빌드 방법

### Debug (개발/테스트)
```bash
xcodebuild -project PhotoRawManager.xcodeproj \
    -scheme PhotoRawManager \
    -configuration Debug build
```

### Release (출시용)
```bash
xcodebuild -project PhotoRawManager.xcodeproj \
    -scheme PhotoRawManager \
    -configuration Release build
```

### Archive (App Store 제출)
Xcode 에서 수동으로:
1. 상단 메뉴 → Product → Archive
2. Organizer 창 자동 열림
3. Distribute App → App Store Connect → Upload

## 파일/폴더 구조

### 중요 파일
| 파일 | 목적 |
|------|------|
| `PhotoRawManager/PhotoRawManager.entitlements` | Sandbox + 권한 |
| `PhotoRawManager/Models/AppConfig.swift` | `hideAIFeatures` 플래그 |
| `PhotoRawManager/Services/TesterKeyService.swift` | 테스터 키 검증 |
| `PhotoRawManager/Services/SandboxBookmarkService.swift` | Security-scoped bookmarks |
| `docs/APP_STORE_SUBMISSION.md` | **App Store 제출 메타데이터** |
| `scripts/prepare_screenshots.sh` | 스크린샷 리사이즈 |
| `TESTER_KEYS.md` | 20개 테스터 키 (**gitignored**) |
| `Secrets.xcconfig` | Google OAuth 키 (**gitignored**) |

### 문서
| 문서 | 내용 |
|------|------|
| `RELEASE.md` | **이 파일** — 출시 체크리스트 |
| `docs/APP_STORE_SUBMISSION.md` | 앱 설명, 심사 노트, IAP 가이드 |
| `website/index.html` | 홈페이지 (gh-pages 배포) |
| `website/privacy.html` | 개인정보 처리방침 |
| `website/terms.html` | 서비스 약관 |

## 예상 타임라인

```
[DAY 0] Apple Developer 결제 완료 ← 현재
   ↓ 24~48시간 대기
[DAY 1-2] Developer Program 승인
   ↓ 즉시
[DAY 2] Team 변경 → Archive → Upload → 심사 제출
   ↓ 24~48시간
[DAY 3-4] 심사 통과
   ↓
[DAY 4] 출시 🎉
```

**총 예상 기간: 3~4일**

## 문제 발생 시

### Archive 실패
- Team 이 Personal Team 인지 확인 → Developer Team 으로 변경 필요
- Bundle ID 등록 여부 확인 (App Store Connect)

### 심사 거부
- 심사 노트에 테스터 키 안내가 누락되지 않았는지 확인
- 스크린샷이 실제 앱과 일치하는지 확인
- 개인정보 처리방침 URL 접근 가능한지 확인

### IAP 가격 승인 지연
- App Store Connect 의 계약 > 세금 > 은행 정보 완료 확인
- 한국 지역 세금 양식 제출 필요
