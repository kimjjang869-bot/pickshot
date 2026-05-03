# PickShot v9.1 출시 전 보안·안정성 감사 보고서

> 감사 일자: 2026-05-02  
> 감사 범위: Services/, Models/, Views/ (주요 파일), git 히스토리  
> 분류 기준: 출시 차단 (CRITICAL) / 출시 후 핫픽스 (HIGH) / 백로그 (MEDIUM/LOW)

---

## 1. 실행 요약

| 티어 | 건수 | 개요 |
|------|------|------|
| 출시 차단 (CRITICAL) | 4건 | OAuth Client Secret 하드코딩·git 노출, Gemini API Key 평문 UserDefaults, Trial 날짜 조작 가능, 로그 업로드 시 IP/hostname PII 무동의 전송 |
| 출시 후 핫픽스 (HIGH) | 5건 | canStartTrial 로직 오류, 사용자 입력 폴더명 경로 인젝션, is.gd 단축 실패 시 전체 긴 URL 노출, 액세스 토큰 10자 평문 로그, Task 해제 누락 |
| 백로그 (MEDIUM/LOW) | 5건 | CLIPTokenizer try! 크래시 가능성, VideoPlayerManager Task.detached 누락 cancel, 로그 파일 무제한 누적, comingSoon 기능 코드 경로 완전 차단 미확인, 로컬 OAuth 서버 Content-Security-Policy 헤더 누락 |

---

## 2. 출시 차단 이슈 (CRITICAL — 반드시 출시 전 수정)

---

### C-1. Google OAuth Client Secret 소스코드 하드코딩 + git 히스토리 영구 노출

**파일:** `PhotoRawManager/Services/Cloud/GoogleDriveService.swift:466–467`

```swift
private static let defaultClientID     = "661638823938-f9bk0a503pv0js0iskdqd196erkg40ua.apps.googleusercontent.com"
private static let defaultClientSecret = "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"
```

**git 히스토리 확인:**  
- `f1da7c8` (2026-04-10) — Client ID 최초 내장  
- `9fd5d07` (2026-04-13) — Client Secret 추가 커밋 (메시지: "OAuth defaultClientSecret 추가")

이 두 커밋은 public/private 여부와 무관하게 git 히스토리에 평문으로 존재한다. DMG 배포 시 `strings` 명령으로 바이너리에서 즉시 추출 가능하다.

**영향:**  
Client Secret이 노출되면 공격자가 PickShot 앱으로 위장하여 임의 사용자의 Google 계정 Drive에 OAuth 코드 교환 요청을 보낼 수 있다(앱 사칭 공격). Google은 Desktop App의 Client Secret을 "not confidential"로 분류하지만, 이는 PKCE 사용 시에 한하며, Secret까지 함께 노출되면 PKCE 없는 코드 교환도 가능해진다.

**재현:** `strings PickShot.app/Contents/MacOS/PickShot | grep GOCSPX`

**권장 조치:**
1. Google Cloud Console에서 현재 Client Secret을 즉시 재발급(rotate)한다.
2. 소스코드에서 `defaultClientSecret` 필드를 삭제하고, `oauthClientSecret`이 Keychain에 없으면 빈 문자열을 반환(PKCE-only 모드)하도록 변경한다.
3. git 히스토리에서 secret을 완전히 제거하려면 `git filter-repo --path-glob "*.swift" --replace-text` 또는 BFG Repo-Cleaner를 사용하고, remote force-push 후 모든 기여자에게 재클론을 안내한다.
4. Client ID는 public이므로 그대로 유지 가능하나, Secret은 절대 소스에 포함하지 않는다.

---

### C-2. Gemini API Key 평문 UserDefaults 저장

**파일:** `PhotoRawManager/Services/AI/GeminiService.swift:48`  
**파일:** `PhotoRawManager/Views/Settings/AIEngineSettingsTab.swift:14`

```swift
// GeminiService.swift
let key = UserDefaults.standard.string(forKey: "GeminiAPIKey")

// AIEngineSettingsTab.swift
@AppStorage("GeminiAPIKey") private var geminiAPIKey = ""
```

Claude API Key는 Keychain에 저장(`KeychainService`)하고 UserDefaults에서 Keychain으로 마이그레이션 경로까지 구현했으나, Gemini API Key는 `UserDefaults`에 평문 저장된다.

**영향:**  
UserDefaults는 macOS 샌드박스 컨테이너 내 plist 파일(`~/Library/Containers/<bundle>/Data/Library/Preferences/<bundle>.plist`)에 평문으로 기록된다. 같은 Mac을 공유하는 다른 사용자나, 백업 파일 접근 권한을 가진 스크립트가 API Key를 쉽게 읽을 수 있다.

**권장 조치:**
1. `GeminiService.getAPIKey()`를 `ClaudeVisionService.getAPIKey()`와 동일하게 Keychain 우선 로드 + UserDefaults 마이그레이션 패턴으로 변경한다.
2. `AIEngineSettingsTab.swift`의 `@AppStorage("GeminiAPIKey")`를 `@State`로 바꾸고, 저장 시 `KeychainService.save(key:value:)`를 호출한다.
3. 기존에 UserDefaults에 저장된 값은 앱 시작 시 `KeychainService.migrateFromUserDefaults`로 1회 자동 마이그레이션한다.

---

### C-3. Trial 시작일 UserDefaults 조작 가능 → 무료 Pro 무기한 사용

**파일:** `PhotoRawManager/Services/SubscriptionManager.swift:99–109`

```swift
private static let trialStartKey = "trialStartDate"

var trialStartDate: Date {
    if let saved = UserDefaults.standard.object(forKey: Self.trialStartKey) as? Date {
        return saved
    }
    let now = Date()
    UserDefaults.standard.set(now, forKey: Self.trialStartKey)
    return now
}
```

Trial 만료까지 남은 일수는 `Date() - UserDefaults["trialStartDate"]`로만 계산한다. 사용자가 `defaults write com.pickshot.app trialStartDate -date "$(date -v+100d)"` 명령 한 줄로 Trial 만료일을 미래로 무기한 연장할 수 있다.

**영향:**  
앱 출시 후 무결제 Pro 무기한 사용. 유료 전환율 직접 손해.

**권장 조치:**
1. `trialStartDate`를 `KeychainService`로 이동하고, 최초 기록 시에만 저장한다(이미 있으면 덮어쓰지 않는다).
2. 추가 방어선: `checkTrialStatus()` 내에서 현재 날짜가 저장일보다 과거이면(시계 조작) Trial 만료로 처리한다.
3. 단기 방어: StoreKit의 `Transaction.currentEntitlements` 기반 `checkCurrentEntitlements()`가 이미 호출되므로, 미구독자는 서버 검증이 되지 않는 Trial에만 의존하게 된다 — Keychain 이동이 최소 대책이다.

---

### C-4. 로그 Google Drive 업로드 시 IP 주소·컴퓨터 이름 무동의 전송

**파일:** `PhotoRawManager/Services/Logger.swift:117–118`

```swift
let fileName = "\(deviceName)_\(localIP)_v\(appVersion)_\(DateFormatter.logDateFormatter.string(from: Date())).log"
```

`sendLogToGoogleDrive()`는 About 화면 버튼("로그 전송")으로 트리거된다. 파일명에 로컬 IP와 컴퓨터 이름이 포함되어 개발자 Google Drive로 전송된다. 로그 본문에는 API 요청 실패 메시지, 파일 경로, 토큰 prefix 등이 포함될 수 있다.

**영향:**  
App Store 심사 지침 5.1.1 (데이터 수집·공개) 위반 가능성. 사용자 동의 없이 식별 가능한 네트워크 정보(IP, 컴퓨터명)를 외부로 전송한다. 개인정보보호법(한국) 및 GDPR(유럽 사용자)에서 사전 동의 필요 항목이다.

**권장 조치:**
1. 파일명에서 `localIP` 제거하고, `deviceName`은 해시 또는 임의 식별자로 치환한다.
2. "로그 전송" 버튼 클릭 전 "이 로그에는 기기 이름과 앱 동작 기록이 포함됩니다. 계속하시겠습니까?" 확인 다이얼로그를 추가한다.
3. 로그 헤더(`buildLogHeader`)에서 `Device`, `Locale`, `IP` 등 식별자 항목을 선택적(opt-in)으로만 기록하도록 수정한다.

---

## 3. 출시 후 핫픽스 (HIGH — 출시 직후 v9.1.x에서 수정)

---

### H-1. canStartTrial 로직 오류 — Trial 진행 중에도 "체험 시작" 버튼 노출

**파일:** `PhotoRawManager/Services/TierManager.swift:88`

```swift
var canStartTrial: Bool {
    let sm = SubscriptionManager.shared
    return sm.isTrialExpired || sm.trialDaysRemaining <= 0
}
```

이 조건은 Trial이 만료됐거나 남은 일수가 0 이하일 때 `true`를 반환한다. 즉, **Trial이 진행 중인 신규 사용자(trialDaysRemaining > 0, isTrialExpired = false)에게도 "7일 무료 체험 시작" 버튼이 노출된다.** 의도는 반대여야 한다: Trial을 아직 쓴 적 없거나 완전 만료된 경우에만 true여야 한다.

**영향:** 혼란스러운 UX. Trial 중인 사용자가 버튼을 눌러 상태가 예상과 다르게 동작할 수 있다.

**권장 조치:**
```swift
var canStartTrial: Bool {
    let sm = SubscriptionManager.shared
    // Trial 미사용(trialStartDate 없음) 또는 완전 만료된 경우만 체험 시작 가능
    return !sm.isTrialExpired == false || sm.trialDaysRemaining <= 0
    // 정확한 의도: Trial이 아직 시작된 적 없는 경우 (UserDefaults에 trialStartDate 없음)
    return UserDefaults.standard.object(forKey: "trialStartDate") == nil
}
```

---

### H-2. 클라이언트 세션 이름이 Google Drive 폴더명으로 그대로 사용 — 경로 구분자 포함 가능

**파일:** `PhotoRawManager/Views/ClientSelectSetupView.swift:137`  
**파일:** `PhotoRawManager/Services/ClientSelectService.swift:388`

```swift
TextField("예: 김철수-이영희 웨딩", text: $sessionName)
// ...
GoogleDriveService.createFolder(name: sessionName, accessToken: token)
// ...
var viewerURL = "\(self?.viewerBaseURL ...)/?session=\(folderID)&name=\(encodedName)..."
```

`sessionName`은 `addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed)`로 URL 인코딩은 되지만, Google Drive 폴더명으로 전달되기 전에 `/`, `\`, `..` 등 파일시스템 경로 구분자 필터링이 없다. 로컬 Google Drive 복사 경로(`copyToGoogleDrive`)에서도 `folderName`을 그대로 `appendingPathComponent`에 전달한다.

**영향:** `../../../` 포함 시 의도치 않은 경로에 파일이 쓰일 수 있다(로컬 Drive 복사 모드). Google REST API는 `/`를 폴더명의 일부로 처리하므로 API에서는 직접적인 traversal은 어렵지만 뷰어 URL 파싱 오류나 세션 조회 실패로 이어진다.

**권장 조치:**
```swift
// 세션 이름 입력 시 sanitize
let sanitizedName = sessionName
    .components(separatedBy: CharacterSet(charactersIn: "/\\:*?\"<>|"))
    .joined(separator: "_")
    .trimmingCharacters(in: .whitespacesAndNewlines)
```

---

### H-3. is.gd URL 단축 실패 또는 응답 지연 시 전체 뷰어 URL(세션명·이메일 포함) 그대로 노출

**파일:** `PhotoRawManager/Services/ClientSelectService.swift:408–422`

```swift
if urlLen > 150 {
    let urlToShorten = viewerURL
    DispatchQueue.global(qos: .userInitiated).async { [weak self] in
        let shortURL = self.shortenURL(urlToShorten)
        if shortURL != urlToShorten && shortURL.hasPrefix("https://is.gd/") {
            DispatchQueue.main.async { self.viewerLink = shortURL }
        }
    }
}
self?.qrCodeImage = self?.generateQRCode(from: viewerURL)  // 원본 URL로 QR 먼저 생성
```

QR 코드는 단축 전 원본 URL로 먼저 생성된다. 단축에 실패하면 `viewerLink`와 QR 코드에 인코딩된 세션명, 클라이언트 이름, 프록시 URL, Drive 폴더 ID가 평문으로 남는다. is.gd는 무료 3rd-party 서비스로 다운타임이 발생할 수 있으며, `sem.wait(timeout: .now() + 8)` 타임아웃으로 8초 지연이 UX에도 영향을 준다.

**영향:** 세션 메타데이터(클라이언트명, 이메일, 폴더 ID) 노출 가능성. 8초 타임아웃이 메인 UI 블로킹은 아니지만 DispatchSemaphore 점유.

**권장 조치:**
1. QR 코드를 단축 URL 완성 후에 생성한다.
2. is.gd 실패 시 "URL 단축 실패, 원본 링크 사용 중" 안내를 표시한다.
3. 장기적으로 is.gd 의존을 제거하고 Cloudflare Worker에 단축 기능을 통합한다.

---

### H-4. Google Drive Access Token 앞 10자 평문 디버그 로그

**파일:** `PhotoRawManager/Services/ClientSelectService.swift:137, 211`

```swift
plog("[CLIENT] 토큰 준비: \(token.prefix(10))...\n")
plog("[CLIENT] executeUploadWorkflow: \(photos.count)장, token=\(token.prefix(10))...\n")
```

`plog`는 `#if DEBUG`에서만 활성화되므로 Release 빌드에서는 컴파일에서 제거된다. 이 자체는 안전하나, 개발 중 토큰 prefix가 디버그 로그 파일에 기록되어 `~/Library/Caches/PickShot/logs/`에 평문 저장된다. "로그 전송" 기능으로 개발자 Drive에도 업로드될 수 있다.

**영향:** 개발 빌드에서 OAuth 토큰 일부가 파일로 남는다. Release에서는 영향 없음.

**권장 조치:**
```swift
// 토큰은 절대 로그에 기록하지 않는다 — 성공/실패 여부만 기록
plog("[CLIENT] 토큰 준비: OK\n")
plog("[CLIENT] executeUploadWorkflow: \(photos.count)장\n")
```

---

### H-5. VideoPlayerManager Task.detached 해제 누락 (잠재적 누수)

**파일:** `PhotoRawManager/Services/VideoPlayerManager.swift:418`

```swift
Task.detached {
    // ...
}
```

`Task.detached`는 현재 actor 컨텍스트와 분리되어 실행되며, 반환된 Task 핸들이 변수에 저장되지 않으면 취소할 수 없다. VideoPlayerManager가 해제될 때 이 Task가 살아있으면 캡처된 self에 대한 참조가 유지된다.

**영향:** VideoPlayerManager deinit 후에도 Task가 실행 중이면 use-after-free 가능성, 메모리 누수.

**권장 조치:**
```swift
// Task 핸들 저장 후 deinit에서 cancel
private var detachedTask: Task<Void, Never>?

detachedTask = Task.detached { [weak self] in ... }

deinit { detachedTask?.cancel() }
```

---

## 4. 백로그 (MEDIUM/LOW — 다음 마이너 버전에서 처리)

---

### M-1. CLIPTokenizer `try!` — 정규식 패턴 변경 시 런타임 크래시

**파일:** `PhotoRawManager/Services/AI/CLIPTokenizer.swift:49`

```swift
wordRegex = try! NSRegularExpression(pattern: pattern, options: [.caseInsensitive])
```

정규식 패턴이 상수이므로 현재는 크래시 위험이 낮지만, `try!`는 패턴 수정 시 디버깅 없이 앱을 즉시 종료시킨다. AI 기능이 Pro에서 활성화되면 실제 사용자에게 영향을 줄 수 있다.

**권장 조치:** `try!` → `try?` 또는 `do/catch`로 교체. 실패 시 경고 로그 출력 후 토크나이저를 비활성화하는 graceful degradation 처리.

---

### M-2. 로컬 OAuth 서버 HTTP 응답에 보안 헤더 누락

**파일:** `PhotoRawManager/Services/Cloud/LocalOAuthServer.swift:156`

```swift
let response = "HTTP/1.1 200 OK\r\nContent-Type: text/html; ...\r\nConnection: close\r\n\r\n\(html)"
```

`X-Frame-Options: DENY`, `Content-Security-Policy`, `X-Content-Type-Options` 헤더가 없다. 로컬호스트 서버이므로 공격 표면이 매우 좁지만, 동일 Mac에서 실행 중인 다른 앱이 127.0.0.1:8085에 iframe으로 접근하는 시나리오가 이론적으로 가능하다.

**권장 조치:** `Content-Security-Policy: default-src 'none'; style-src 'unsafe-inline'`과 `X-Frame-Options: DENY` 헤더 추가.

---

### M-3. 디버그 로그 파일 무제한 누적

**파일:** `PhotoRawManager/Services/Logger.swift:31–36`

로그는 날짜별 파일로 `~/Library/Caches/PickShot/logs/`에 누적되지만 자동 삭제 정책이 없다. 장기 사용자의 경우 수십 MB가 누적된다. 로그에는 파일 경로, 사진 이름, API 오류 메시지 등이 포함된다.

**권장 조치:** 앱 시작 시 30일 이상 된 로그 파일을 자동 삭제하는 `CacheSweeper` 연동.

---

### M-4. viewerBaseURL UserDefaults 값 검증 없이 URL 생성에 사용

**파일:** `PhotoRawManager/Services/ClientSelectService.swift:32–35`

```swift
var viewerBaseURL: String {
    UserDefaults.standard.string(forKey: "clientSelectViewerURL")
        ?? "https://kimjjang869-bot.github.io/pickshot-viewer"
}
```

사용자가 임의로 `clientSelectViewerURL` UserDefaults 값을 변경하면 `javascript:`, `file://`, 또는 `http://` 스킴의 URL이 뷰어 링크로 생성될 수 있다. `NSWorkspace.shared.open(url)`로 열릴 경우 임의 URL이 브라우저에서 열린다.

**영향:** 내부 설정 변경 가능한 고급 사용자 또는 악성 앱의 UserDefaults 조작 시 피싱 링크 생성 가능성. 일반 사용자는 이 값에 접근할 UI가 없으므로 실제 공격 가능성은 낮다.

**권장 조치:**
```swift
var viewerBaseURL: String {
    let custom = UserDefaults.standard.string(forKey: "clientSelectViewerURL") ?? ""
    // https:// 스킴만 허용
    if custom.hasPrefix("https://"), URL(string: custom) != nil {
        return custom.trimmingCharacters(in: .init(charactersIn: "/"))
    }
    return "https://kimjjang869-bot.github.io/pickshot-viewer"
}
```

---

### M-5. 사진 데이터의 외부 API 전송 — 개인정보 처리방침 명시 필요

**파일:** `PhotoRawManager/Services/AI/ClaudeVisionService.swift:82–95`  
**파일:** `PhotoRawManager/Services/AI/GeminiService.swift:68–99`

Claude/Gemini Vision 기능은 사진 JPEG 데이터를 base64로 인코딩하여 각각 `api.anthropic.com`, `generativelanguage.googleapis.com`으로 전송한다. EXIF 정보(촬영 일시, 카메라 기종)는 이미지 리사이즈/인코딩 과정에서 일부 제거되나, 이미지 자체에 GPS 태그나 피사체 정보가 포함될 수 있다.

**영향:** 개인정보보호법 및 App Store 개인정보 처리 방침 요건상 "사진이 외부 AI 서버로 전송될 수 있음"을 사용자에게 고지하고 동의를 받아야 한다. 현재 설정 화면에서 API 키 입력 안내는 있으나 명시적 동의 흐름이 없다.

**권장 조치:** AI 기능 첫 사용 시 "이 기능은 사진 이미지를 Anthropic/Google 서버로 전송합니다. 계속하시겠습니까?" 1회 동의 다이얼로그 추가. `InfoPrivacy` 설명 업데이트.

---

## 5. 빠른 수정 우선순위 TOP 5 (1일 이내 완료 가능)

| 우선순위 | 항목 | 수정 시간 (예상) | 파일 |
|----------|------|----------------|------|
| 1 | **C-1** Google OAuth Client Secret 삭제 + rotate | 30분 | GoogleDriveService.swift:467 |
| 2 | **C-2** Gemini API Key → Keychain 이전 | 1시간 | GeminiService.swift, AIEngineSettingsTab.swift |
| 3 | **C-3** trialStartDate → Keychain 이전 | 1시간 | SubscriptionManager.swift:99–109 |
| 4 | **C-4** 로그 파일명에서 IP 제거 + 전송 전 동의 다이얼로그 | 30분 | Logger.swift:118 |
| 5 | **H-4** Access Token prefix 로그 제거 | 5분 | ClientSelectService.swift:137, 211 |

---

## 6. 항목별 검사 결과 요약

| 검사 항목 | 결과 | 비고 |
|-----------|------|------|
| 하드코딩된 API 키/Secret | CRITICAL | OAuth Client Secret (C-1) |
| git 히스토리 노출 | CRITICAL | 커밋 f1da7c8, 9fd5d07 |
| Secrets.xcconfig git 포함 여부 | 양호 | .gitignore 확인됨 |
| Keychain 사용 일관성 | HIGH | Gemini Key만 누락 (C-2) |
| 구독/티어 우회 가능성 | CRITICAL | Trial 날짜 UserDefaults (C-3) |
| StoreKit 영수증 검증 | 양호 | checkVerified() 사용, unverified 예외 처리 |
| OAuth CSRF 방지 | 양호 | state 파라미터 검증 구현됨 |
| OAuth PKCE | 양호 | PKCE S256 사용됨 |
| TLS 강제 적용 | 양호 | 모든 API URL이 https:// |
| 사용자 입력 → 파일 경로 | MEDIUM | sessionName 폴더명 sanitize 미흡 (H-2) |
| 외부 API로 이미지 전송 | MEDIUM | Claude/Gemini Vision, 동의 흐름 필요 (M-5) |
| force unwrap / try! | LOW | CLIPTokenizer.swift:49 (M-1) |
| Task 누수 | LOW | VideoPlayerManager Task.detached (H-5) |
| 로그 민감정보 | HIGH | IP/hostname 전송 (C-4), 토큰 prefix (H-4) |
| comingSoon 런타임 차단 | 양호 | AppConfig + FeatureGate 이중 방어 |
| TesterKeyService 보안 | 양호 | SHA256 해시 비교, Keychain 저장 |

---

## 7. 부록: 검사 제외 항목

- `Secrets.xcconfig` 파일 — `.gitignore`에 포함되어 git에 커밋된 이력 없음. 현재 파일 내용은 검사하지 않았음.
- App Store Connect 서버 측 영수증 검증 — StoreKit 2 `Transaction.currentEntitlements` 사용 중이며, Apple 서버 검증을 활용하므로 별도 서버 구현 불필요. 적절한 구현으로 판단.
- 외부 의존성(npm audit 해당 없음) — Swift 패키지는 확인 가능한 Package.swift 없음.
