# PickShot 피드백 게시판 — Cloudflare 배포 가이드

`docs/board-worker.js` 를 Cloudflare Workers 에 배포하고 `website/feedback.html` 과 연결하는 5분 가이드.

---

## 사전 준비

- Cloudflare 무료 계정 (https://dash.cloudflare.com 에서 가입)
- 신용카드 등록 불필요 (Workers Free plan: 일 100k 요청)

---

## 1단계 — KV 네임스페이스 만들기 (먼저 만들어야 워커에 바인딩 가능)

1. https://dash.cloudflare.com 접속
2. 좌측 사이드바 → **Workers & Pages** → **KV** 클릭
3. **Create a namespace** 버튼
4. 이름: `BOARD` 입력 → **Add**

> KV 는 키-값 저장소. 게시판 글/댓글이 여기에 저장됨.

---

## 2단계 — Worker 생성

1. 좌측 **Workers & Pages** → **Create application** → **Create Worker**
2. Worker 이름: `pickshot-board` (원하는 이름 가능, 단 URL 에 들어감)
3. **Deploy** 클릭 (기본 Hello World 워커가 일단 배포됨)

---

## 3단계 — 코드 붙여넣기

1. 방금 만든 워커 클릭 → 우상단 **Edit code** 버튼
2. 에디터 좌측에 보이는 기본 `worker.js` 내용을 **전부 삭제**
3. 로컬 저장소의 `docs/board-worker.js` 파일 전체를 복사해서 붙여넣기
4. 우상단 **Deploy** → 확인 팝업에서 **Save and deploy**

---

## 4단계 — KV 네임스페이스 바인딩

워커가 KV 에 접근하려면 환경변수처럼 바인딩이 필요함.

1. 워커 페이지에서 **Settings** 탭 → **Variables and Secrets** (또는 **Bindings**) 메뉴
2. **KV Namespace Bindings** 섹션 → **Add binding**
3. 입력값:
   - **Variable name**: `BOARD` (반드시 대문자 — 코드에서 `env.BOARD` 로 참조)
   - **KV namespace**: 1단계에서 만든 `BOARD` 선택
4. **Save and deploy**

---

## 5단계 — 워커 URL 복사

1. 워커 페이지 상단에 표시된 URL 확인
   - 형식: `https://pickshot-board.<계정명>.workers.dev`
2. 브라우저로 접속해서 동작 확인
   - `https://pickshot-board.<계정명>.workers.dev/posts?board=bug` 입력
   - `{"posts":[]}` 같은 빈 JSON 응답이 나오면 정상

---

## 6단계 — feedback.html 에 URL 연결

`website/feedback.html` 251 줄 부근:

```javascript
// 변경 전
const BOARD_API = '';

// 변경 후 (5단계에서 복사한 URL 붙여넣기)
const BOARD_API = 'https://pickshot-board.<계정명>.workers.dev';
```

저장 → 커밋 → push → GitHub Pages 가 자동으로 배포.

---

## 7단계 — 동작 확인

1. https://kimjjang869-bot.github.io/pickshot/feedback.html 접속
2. 우상단 경고 박스가 사라졌는지 확인 (사라지면 BOARD_API 인식 OK)
3. 글 작성 → 작성 완료 → 목록에 표시되면 끝

---

## 운영 옵션 (배포 후 추천)

### CORS 제한 (선택)

`board-worker.js` 32 줄:

```javascript
// 변경 전 (모든 출처 허용)
const CORS_ORIGIN = '*';

// 변경 후 (본인 사이트만 허용)
const CORS_ORIGIN = 'https://kimjjang869-bot.github.io';
```

→ 워커 코드 수정 후 **Deploy** 만 다시 누르면 즉시 반영.

### Rate limit 조정

같은 파일 33 줄 `RATE_LIMIT_PER_HOUR = 5` — IP 당 시간당 게시 가능 횟수.
스팸이 많으면 줄이고, 사용자 불편 호소 시 늘리면 됨.

---

## 트러블슈팅

| 증상 | 원인 | 해결 |
|------|------|------|
| `BOARD is not defined` 에러 | KV 바인딩 누락 | 4단계 다시 |
| `1101 Worker threw exception` | 코드 붙여넣기 누락/오타 | 3단계 다시 |
| `CORS error` 콘솔 | feedback.html 도메인이 CORS_ORIGIN 에 없음 | 워커의 `CORS_ORIGIN` 을 `'*'` 로 임시 되돌리고 확인 |
| 글이 안 보임 | KV 전파 지연 (~수 초) | 새로고침 |
| `404 Not Found` | 워커 URL 오타 / 워커가 deploy 안 됨 | `https://<URL>/` 직접 접속해서 응답 확인 |

---

## 참고

- 워커 코드: [docs/board-worker.js](board-worker.js)
- 프론트엔드: [website/feedback.html](../website/feedback.html)
- 무료 한도 초과 시: KV 쓰기 1k/day → Workers Paid ($5/mo) 로 업그레이드
