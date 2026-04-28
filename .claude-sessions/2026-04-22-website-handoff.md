# PickShot 홈페이지 작업 — 세션 핸드오프

**날짜**: 2026-04-22
**목적**: 홈페이지 수정 작업 전용 세션 (앱 코드와 분리)

## 📁 위치
```
/Users/potokan/PhotoRawManager/website/
├── index.html      (24.7K)  메인 랜딩
├── style.css       (37K)    갤럭시 테마
├── script.js       (10.7K)  애니메이션/상호작용
├── privacy.html    (7.6K)   개인정보처리방침
└── terms.html      (7.8K)   서비스 이용약관
```

## 🎨 현재 디자인 상태
- **테마**: 갤럭시 (v8.8.1 리디자인)
- **최근 커밋**:
  - `2c9acc0` docs(web): design critique 반영 — Hero 앱 목업 + CTA 통일 + 이탤릭 축소
  - `0c2b549` docs(web): v8.8.1 홈페이지 갤럭시 테마 리디자인
  - `9767eb2` docs(web): v8.8.1 홈페이지 대대적 리디자인
  - `1e4134e` docs(web): v8.8.1 다운로드 링크 업데이트

## 🎯 PickShot 현재 버전
- **앱 버전**: v8.9.1 (방금 커밋: `d45c8cb`)
- **GitHub**: https://github.com/kimjjang869-bot/pickshot
- **최신 기능 (홈페이지에 반영 필요할 수도)**:
  - 메모리 18GB → 221MB (98.8% 감소)
  - 클릭 응답성 4배 개선 (1162ms → 307ms)
  - 연사 베스트 자동 선별 (CLIP 유사도)
  - 사용자 학습 (취향 프로필)
  - 같은 옷 검색 (CLIP)
  - AdaFace 얼굴 검색 (99.82%)

## 🚨 주의사항
- **유료 앱**: 홍보 문구에 "무료"라고 쓰지 말 것 (memory: project_pricing.md)
- **존댓말 통일**: 안내 문구 (memory: feedback_speech_style.md)
- 사용자 명시 시에만 git commit/push

## 🌐 배포
- gh-pages 브랜치 (v8.2.1 부터 GitHub Pages 배포)
- 도메인: 미확인 (필요시 README 또는 CNAME 확인)

## 🚀 새 세션 시작 명령
```
/Users/potokan/PhotoRawManager/.claude-sessions/2026-04-22-website-handoff.md
읽고 홈페이지 수정 시작
```

## 📝 앱 코드 작업 핸드오프 참고
- v8.9 메모리: `.claude-sessions/2026-04-22-v8.9-memory-handoff.md`
- v8.9 Phase 3+: `.claude-sessions/2026-04-22-v8.9-memory-phase3-handoff.md`
