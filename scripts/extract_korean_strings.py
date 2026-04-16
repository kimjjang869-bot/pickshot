#!/usr/bin/env python3
"""
Swift 소스에서 SwiftUI Text/Button/Label 등 사용자 대면 API 호출에 포함된
한글 문자열을 추출.

전략:
- AST 없이 정규식만으로 처리
- 주석/로그 함수(print/fputs/AppLogger/NSLog/Logger) 라인 전체 제외
- 남은 라인 중 "..." 리터럴 안에 한글 포함된 것 추출
- \n, \" 같은 Swift escape 은 실제 문자로 변환해서 저장 (xcstrings 호환)
"""

import re
import json
import csv
from pathlib import Path

ROOT = Path("/Users/potokan/PhotoRawManager/PhotoRawManager")
OUTPUT_XCSTRINGS = ROOT / "Localizable.xcstrings"
OUTPUT_CSV = ROOT.parent / "scripts" / "strings_to_translate.csv"

STRING_LITERAL_RE = re.compile(r'"((?:[^"\\]|\\.)*)"')
KOREAN_RE = re.compile(r'[가-힣]')

# 이 중 하나가 포함된 라인은 완전히 무시 (로깅/디버그)
SKIP_RE = re.compile(
    r'//'                           # 주석
    r'|\bAppLogger\b'
    r'|\bprint\b\s*\('
    r'|\bfputs\b\s*\('
    r'|\bNSLog\b\s*\('
    r'|\bos_log\b\s*\('
    r'|\bLogger\b\s*\('
    r'|\blogger\.'
    r'|\bNSLocalizedString\s*\('
    r'|\bLocalizedStringKey\s*\('
    r'|\bassertionFailure\b'
    r'|\bprecondition\b'
    r'|\bfatalError\b'
    r'|\bassert\s*\('
)


def decode_swift_string(s: str) -> str:
    """Swift 문자열 escape 을 파이썬 문자열로 안전하게 디코드"""
    # \( 보간은 리터럴로 남기고, \n \t \" \\ 만 디코드
    out = []
    i = 0
    while i < len(s):
        c = s[i]
        if c == '\\' and i + 1 < len(s):
            nxt = s[i+1]
            if nxt == 'n':
                out.append('\n'); i += 2; continue
            if nxt == 't':
                out.append('\t'); i += 2; continue
            if nxt == 'r':
                out.append('\r'); i += 2; continue
            if nxt == '"':
                out.append('"'); i += 2; continue
            if nxt == '\\':
                out.append('\\'); i += 2; continue
            # \( ... ) 같은 보간은 리터럴 유지
            out.append(c); out.append(nxt); i += 2; continue
        out.append(c); i += 1
    return ''.join(out)


def extract_from_line(line: str):
    if SKIP_RE.search(line):
        return []
    results = []
    for m in STRING_LITERAL_RE.finditer(line):
        raw = m.group(1)
        if not KOREAN_RE.search(raw):
            continue
        results.append(decode_swift_string(raw))
    return results


def main():
    all_strings = set()
    # UI 코드만: Views + Models 이지만 Models 는 메시지 쓰는 일부만
    # Services 는 UI 표시용 서비스만 선택
    patterns = [
        "Views/**/*.swift",
        "*.swift",  # PhotoRawManagerApp.swift
        "Services/GSelectService.swift",
        "Services/ClientSelectService.swift",
        "Services/TetherService.swift",
        "Services/MemoryCardBackupService.swift",
        "Services/TesterKeyService.swift",
        "Services/UpdateService.swift",
        "Services/Cloud/GoogleDriveService.swift",
    ]
    swift_files = []
    seen = set()
    for p in patterns:
        for sf in ROOT.glob(p):
            k = sf.resolve()
            if k not in seen:
                swift_files.append(sf)
                seen.add(k)

    # Models/PhotoStore+Folder.swift 등 UI 메시지가 있는 일부만 추가
    extra_models = [
        "Models/PhotoStore+Folder.swift",
        "Models/PhotoStore+Move.swift",
        "Models/PhotoStore+Export.swift",
        "Models/PhotoStore+Match.swift",
    ]
    for e in extra_models:
        sf = ROOT / e
        if sf.exists() and sf.resolve() not in seen:
            swift_files.append(sf); seen.add(sf.resolve())

    print(f"검색 대상 (UI 한정): {len(swift_files)} Swift 파일")

    per_file = {}
    for sf in swift_files:
        try:
            text = sf.read_text(encoding='utf-8')
        except Exception:
            continue

        in_block = False
        c = 0
        for line in text.split('\n'):
            stripped = line.strip()
            if in_block:
                if '*/' in stripped: in_block = False
                continue
            if stripped.startswith('/*') and '*/' not in stripped:
                in_block = True; continue
            for s in extract_from_line(line):
                all_strings.add(s); c += 1
        if c:
            per_file[sf.relative_to(ROOT)] = c

    sorted_strings = sorted(all_strings)
    print(f"\n총 추출 한글 (unique): {len(sorted_strings)}개")
    print(f"\n상위 10개 파일:")
    for f, c in sorted(per_file.items(), key=lambda x: -x[1])[:10]:
        print(f"  {f}: {c}개")

    if OUTPUT_XCSTRINGS.exists():
        catalog = json.loads(OUTPUT_XCSTRINGS.read_text(encoding='utf-8'))
    else:
        catalog = {"sourceLanguage": "ko", "strings": {}, "version": "1.0"}

    added = 0
    for s in sorted_strings:
        if s not in catalog["strings"]:
            catalog["strings"][s] = {
                "extractionState": "manual",
                "localizations": {
                    "ko": {"stringUnit": {"state": "translated", "value": s}}
                }
            }
            added += 1

    OUTPUT_XCSTRINGS.write_text(
        json.dumps(catalog, ensure_ascii=False, indent=2), encoding='utf-8'
    )
    print(f"\n✅ {OUTPUT_XCSTRINGS.name}: +{added} (전체 {len(catalog['strings'])})")

    # 번역 대기 목록
    untranslated = []
    for key, entry in catalog['strings'].items():
        en = (entry.get('localizations', {})
                   .get('en', {}).get('stringUnit', {}).get('value', '')).strip()
        if not en:
            untranslated.append(key)

    with open(OUTPUT_CSV, 'w', encoding='utf-8', newline='') as f:
        w = csv.writer(f)
        w.writerow(["key", "korean", "english"])
        for k in untranslated:
            w.writerow([k, k, ""])

    print(f"📋 번역 대기 CSV: {OUTPUT_CSV} ({len(untranslated)}개)")


if __name__ == "__main__":
    main()
