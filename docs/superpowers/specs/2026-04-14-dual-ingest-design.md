# 듀얼 백업 인제스트 — 설계 문서

- 작성일: 2026-04-14
- 대상 버전: v8.1 예정
- 관련 기존 파일: `Services/MemoryCardBackupService.swift`, `Services/FileCopyService.swift`

## 목표

Photo Mechanic 스타일의 **2개 디스크 동시 백업 + 인제스트 시 이름변경/폴더분류** 지원. 현장에서 카메라 2~3대 운용하는 워크플로우에 맞춘 멀티카메라 자동 분류 포함.

## 비목표

- 3개 이상 동시 백업 (YAGNI — 실제 사례 드묾)
- 자동 재시도 정책 (수동 재시도 버튼만 제공)
- IPTC 메타데이터 템플릿 주입 (별도 기능으로 분리)
- 클라우드 동시 업로드 (별도 기능)

## 사용자 시나리오

**시나리오 1 — 단일 카드 듀얼 백업 (웨딩 사진가)**
1. SD카드 꽂음 → Primary SSD + Secondary HDD 동시 복사
2. 파일명은 `{date}_{seq}` 패턴으로 자동 변경
3. 둘 다 성공 → 카드 자동 언마운트 → 토스트 알림

**시나리오 2 — 멀티카메라 (행사 사진가)**
1. 카메라 3대 (R5 메인, R5 서브, A7)
2. 카드 3장 순차적으로 꽂음
3. 첫 R5 카드 꽂았을 때 별칭 입력 모달 → "R5-메인" 저장
4. 둘째 R5 카드 꽂음 → 같은 모델 감지 → "R5-서브" 입력
5. A7 카드 → "A7" 입력
6. 모든 카드가 `{date}/{camera}/` 구조로 자동 분류 복사됨

**시나리오 3 — 멀티 카드 동시 삽입 (듀얼 슬롯 리더)**
1. 카드 2장 동시 꽂음 → 2개 IngestSession 병렬 실행
2. 각각 Primary/Secondary로 복사 (최대 4개 BackupSession 병렬)
3. 툴바 진행률에 4개 세션 표시

## 아키텍처

### 레이어 구성

```
┌─────────────────────────────────────────────┐
│ UI Layer                                    │
│  IngestSettingsView · IngestProgressBar    │
│  CameraAliasPromptView                     │
└─────────────────────────────────────────────┘
                  ↓
┌─────────────────────────────────────────────┐
│ Service Layer (신규)                        │
│  IngestService (오케스트레이션)             │
│  IngestPlanner (경로 계산, 순수 함수)       │
│  CameraAliasStore (UserDefaults)           │
└─────────────────────────────────────────────┘
                  ↓
┌─────────────────────────────────────────────┐
│ 기존 Layer                                  │
│  MemoryCardBackupService (볼륨 감지)        │
│  BackupSession (단일 복사 세션)             │
│  FileCopyService.fastCopy (저수준 복사)     │
└─────────────────────────────────────────────┘
```

### 신규 타입

```swift
// 하나의 카드를 Primary+Secondary로 복사하는 상위 단위
class IngestSession: ObservableObject, Identifiable {
    let id = UUID()
    let volumeURL: URL
    let cameraModel: String       // EXIF에서 추출한 모델명
    let cameraAlias: String       // 사용자 지정 별칭 (R5-메인 등)
    let primary: BackupSession
    let secondary: BackupSession? // nil이면 단일 백업
    let settings: IngestSettings
    @Published var verifyMode: VerifyMode
    @Published var isComplete: Bool = false
}

enum VerifyMode {
    case sizeOnly       // 기본
    case md5            // 옵션: 해시 검증
}

struct IngestSettings: Codable {
    var primaryDestination: URL?
    var secondaryDestination: URL?  // nil이면 단일
    var folderStructure: FolderStructure
    var renamePattern: String?       // nil이면 원본 파일명
    var verifyMode: VerifyMode
}

enum FolderStructure: String, Codable {
    case original            // 원본 그대로
    case dateOnly            // {date}/
    case dateCamera          // {date}/{camera}/   (추천)
    case cameraDate          // {camera}/{date}/
}

struct CameraAlias: Codable {
    let volumeUUID: String   // 디스크 UUID (카드별 영구 식별)
    let cameraModel: String
    let alias: String        // 사용자 입력 (R5-메인)
}
```

### 기존 타입 변경

- `BackupSession`: 변경 없음, 재사용
- `MemoryCardBackupService`:
  - `sessions: [BackupSession]` 제거, `ingestSessions: [IngestSession]` 추가
  - `startBackup()` → `startIngest()` 로 변경. 실제 복사 실행은 `IngestService.execute()` 에 위임
  - 볼륨 감지/언마운트 로직만 유지

## 동작 흐름

```
[카드 Mount 이벤트]
  ↓
NSWorkspace.didMountNotification
  ↓
MemoryCardBackupService.checkAndPromptIfMemoryCard(volumeURL)
  ├── DCIM 디렉토리 감지
  ├── 첫 JPG EXIF 읽기 → cameraModel 추출
  ├── 볼륨 UUID 조회 → CameraAliasStore 룩업
  │   ├── 있으면: 저장된 alias 사용
  │   └── 없으면: CameraAliasPromptView 모달 표시
  ↓
IngestPlanner.plan(volume, settings, alias)
  ├── 폴더 구조 경로 계산: /SSD1/2026-04-14/R5-메인/
  ├── 파일명 패턴 적용: R5_0001.CR3 → {camera}_{seq} → R5-메인_0001.CR3
  ├── 충돌 감지: 타겟 파일 이미 존재 시 파일크기 비교 → 같으면 skip, 다르면 " (n)" suffix
  └── IngestPlan 리턴 (source → target 매핑 리스트)
  ↓
IngestService.execute(plan, settings)
  ├── IngestSession 생성 (primary + secondary BackupSession)
  ├── 2개 병렬 실행 (DispatchQueue.concurrentPerform)
  │   ├── FileCopyService.fastCopy (기존 코드)
  │   ├── 크기 검증 (기존 로직)
  │   └── [옵션] MD5 검증 (신규)
  └── 결과 집계
  ↓
[완료 처리]
  ├── 둘 다 성공 → diskutil eject (자동 언마운트)
  │               → 토스트 "카드 백업 완료"
  ├── 한쪽 실패 → 카드 유지
  │               → "Secondary 재시도?" 모달
  └── 실패 로그 → BackupResult.failed 에 기록
```

## UI 설계

### 인제스트 설정 화면 (Settings 창 새 탭)

```
┌─ 인제스트 설정 ────────────────────────────────┐
│                                                │
│ Primary:   [/Volumes/SSD1/Photos    ] [변경]   │
│ ☐ Secondary: [선택...              ] [변경]   │
│                                                │
│ 폴더 구조:                                     │
│   ○ 원본 그대로 (현재)                         │
│   ● 날짜/카메라/                (추천)          │
│   ○ 카메라/날짜/                                │
│   ○ 날짜/                                       │
│                                                │
│ ☐ 파일명 변경                                   │
│     패턴: [{camera}_{seq}        ] [편집]      │
│     미리보기: R5-메인_0001.CR3                  │
│                                                │
│ ☐ 해시 검증 (느림, 중요 촬영 권장)              │
│                                                │
└────────────────────────────────────────────────┘
```

### 카메라 별칭 입력 모달 (첫 감지 시만)

```
┌─ 새 카드 감지 ──────────────────────────────┐
│                                              │
│  📷  Canon EOS R5                            │
│      카드 라벨: NIKON D850                   │
│      사진 1,234장 · 48.2 GB                  │
│                                              │
│  이 카드 별칭:                                │
│  [R5-메인                          ]         │
│                                              │
│  (다음에 같은 카드 꽂으면 자동 인식됩니다)      │
│                                              │
│         [취소]    [이 카드로 저장]            │
└──────────────────────────────────────────────┘
```

### 툴바 진행률 바

**평소 (접힌 상태):**
```
[🔵🔵🟢 3개 · 72% · 2분]
```

**클릭 시 펼침:**
```
┌─ 백업 (3개 진행중, 예상 2분 남음) ──────────┐
│ CAM1 (R5-메인) → SSD1  ████░  72%  42MB/s  │
│ CAM1 (R5-메인) → SSD2  ████░  71%  41MB/s  │
│ CAM2 (A7)      → SSD1  █████  88%  38MB/s  │
│                              [모두 취소]    │
└─────────────────────────────────────────────┘
```

**완료 시 토스트:**
```
✅ 3개 카드 백업 완료 (총 3,421장 / 152 GB)
```

## 에러 처리

| 상황 | 처리 |
|------|------|
| 파일 복사 실패 (I/O 에러) | 3회 재시도 (기존 로직) → 실패 시 `FailedFile` 기록, 다음 파일 계속 |
| 파일 크기 불일치 | 재복사. 3회 후도 불일치면 실패 기록 |
| MD5 해시 불일치 (옵션 ON) | 재시도 없음 (실제 손상 가능성) → 실패 기록 |
| Secondary 디스크 꽉 참 | Primary만 완료, Secondary 실패 처리. 카드 유지 + 사용자에게 안내 |
| Primary 디스크 꽉 참 | Primary 중단, Secondary 완료. 카드 유지 (Primary 공간 확보 후 재시도 필요) |
| 복사 중 카드 뽑힘 | NSWorkspace.didUnmountNotification 수신 → 세션 취소 → 실패 알림 |
| EXIF 없는 파일 | cameraModel = "Unknown", 폴더 구조에 "Unknown" 사용 |
| 별칭 모달 취소 | 인제스트 취소 |

## 데이터 저장

**UserDefaults 키:**
- `ingest.primaryDestination`: String (URL path)
- `ingest.secondaryDestination`: String? (nil이면 단일)
- `ingest.folderStructure`: String (FolderStructure.rawValue)
- `ingest.renamePattern`: String? (nil이면 원본)
- `ingest.verifyMode`: String
- `cameraAliases`: [CameraAlias] (JSON 인코딩)

## 테스트 전략

### 단위 테스트

**IngestPlannerTests**
- EXIF date 추출 → `{date}/` 폴더명 생성
- cameraModel + alias → `{date}/{camera}/` 폴더명 생성
- 파일명 패턴 토큰 치환 (`{camera}_{seq}` → `R5-메인_0001`)
- 파일 충돌 시 " (2)" suffix 생성
- EXIF 없는 파일 → "Unknown" fallback

**CameraAliasStoreTests**
- UUID로 별칭 저장/조회
- 없는 UUID 조회 → nil
- 기존 UUID 재저장 → 덮어쓰기

### 통합 테스트

**IngestServiceTests**
- 임시 디렉토리 2개 (primary/secondary) 만들어 10장 복사
- 파일 수/크기/해시 검증
- Secondary 디스크 full 시뮬레이션 (작은 디스크 이미지 마운트)
- 중간 취소 (isCancelled = true) → 부분 복사 상태 정리

### 수동 테스트

- [ ] 실제 SD카드 → 듀얼 백업 (Primary/Secondary)
- [ ] 같은 카메라 모델 2대 → 별칭 구분 확인
- [ ] 멀티 카드 동시 삽입 (4개 세션 병렬 진행률)
- [ ] 복사 중 케이블 뽑기 → 에러 처리
- [ ] 해시 검증 ON → 속도 비교
- [ ] 기존 단일 백업 사용자 워크플로우 호환 (Secondary OFF)

## 마이그레이션

기존 `MemoryCardBackupService` 사용자 데이터:
- `destinationURL` UserDefaults → `ingest.primaryDestination`으로 자동 이관 (첫 실행 시)
- 기존 단일 백업 동작 유지 (Secondary OFF 상태로 시작)

## 신규/수정 파일

### 신규
1. `Services/IngestService.swift` — 복사 오케스트레이션
2. `Services/IngestPlanner.swift` — 경로 계산 (순수 함수)
3. `Services/CameraAliasStore.swift` — 별칭 영속성
4. `Models/IngestSession.swift` — 세션 모델
5. `Models/IngestSettings.swift` — 설정 모델
6. `Views/IngestSettingsView.swift` — 설정 UI
7. `Views/IngestProgressBar.swift` — 툴바 진행률
8. `Views/CameraAliasPromptView.swift` — 별칭 모달
9. (테스트) `IngestPlannerTests.swift`, `CameraAliasStoreTests.swift`, `IngestServiceTests.swift`

### 수정
- `Services/MemoryCardBackupService.swift` — 볼륨 감지만 담당, 실제 복사는 IngestService에 위임
- `PhotoRawManagerApp.swift` — IngestSettingsView 탭 등록
- `Views/ContentView+Toolbar.swift` — IngestProgressBar 추가
- `Views/SettingsView.swift` — 인제스트 탭 추가

## 성능 목표

- 64GB 카드 (~2,000장 JPG+RAW): 듀얼 백업 8분 이내 (USB-C 3.2 기준, 순수 I/O 시간)
- 해시 검증 ON 시: +30% 시간 허용
- 진행률 업데이트: 100ms 이내 (기존 수준)
- 여러 세션 병렬: CPU 코어 활용 (각 세션 독립 스레드)

## 릴리즈 계획

- **M1 (1주)**: IngestPlanner + CameraAliasStore + 단위 테스트
- **M2 (1주)**: IngestService + BackupSession 통합 + 통합 테스트
- **M3 (1주)**: UI 3개 (Settings, Modal, ProgressBar)
- **M4 (3일)**: 통합 테스트 + 수동 테스트 + 문서
- **v8.1 릴리즈**: 총 ~3주
