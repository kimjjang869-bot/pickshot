#!/usr/bin/env python3
"""
Swift 소스 코드에서 한글이 포함된 사용자 대면 문자열(Text/Button/Label 등)을 추출.
Localizable.xcstrings 에 넣을 기본 엔트리를 생성합니다.

추출 대상 (SwiftUI 자동 localize):
- Text("한글...")
- .navigationTitle("한글...")
- .help("한글...")
- Label("한글...", systemImage: ...)
- Button("한글...")
- TextField("한글...", text: ...)
- .alert("한글...")
- Toggle("한글...", ...)

제외:
- print / fputs / AppLogger 로그 메시지 (개발자용)
- NSLocalizedString 호출 (이미 localized)
- 주석 (//, /* */)
- 문자열 안의 한글이 아닌 단순 이모지/기호
"""

import os
import re
import json
import sys
from pathlib import Path

ROOT = Path("/Users/potokan/PhotoRawManager/PhotoRawManager")
OUTPUT_XCSTRINGS = ROOT / "Localizable.xcstrings"

# SwiftUI 자동 localized 함수들 (Text + 유사)
# 더 확장하려면 여기에 추가
AUTO_LOCALIZED_PATTERNS = [
    r'Text\("([^"\\]*[가-힣][^"\\]*)"\)',
    r'\.navigationTitle\("([^"\\]*[가-힣][^"\\]*)"\)',
    r'\.navigationSubtitle\("([^"\\]*[가-힣][^"\\]*)"\)',
    r'\.help\("([^"\\]*[가-힣][^"\\]*)"\)',
    r'Label\("([^"\\]*[가-힣][^"\\]*)"',
    r'Button\("([^"\\]*[가-힣][^"\\]*)"\)',
    r'Button\("([^"\\]*[가-힣][^"\\]*)"\s*,',
    r'TextField\("([^"\\]*[가-힣][^"\\]*)"',
    r'SecureField\("([^"\\]*[가-힣][^"\\]*)"',
    r'Toggle\("([^"\\]*[가-힣][^"\\]*)"',
    r'Picker\("([^"\\]*[가-힣][^"\\]*)"',
    r'\.alert\("([^"\\]*[가-힣][^"\\]*)"',
    r'\.confirmationDialog\("([^"\\]*[가-힣][^"\\]*)"',
    r'Section\("([^"\\]*[가-힣][^"\\]*)"',
    r'Link\("([^"\\]*[가-힣][^"\\]*)"',
    r'Stepper\("([^"\\]*[가-힣][^"\\]*)"',
    r'ContextMenu\s*\{[^}]*Button\("([^"\\]*[가-힣][^"\\]*)"',
    r'Menu\("([^"\\]*[가-힣][^"\\]*)"',
    r'DisclosureGroup\("([^"\\]*[가-힣][^"\\]*)"',
]

# 로그/디버그용 문자열은 스킵
SKIP_PATTERNS = [
    r'print\(',
    r'fputs\(',
    r'AppLogger',
    r'NSLog',
    r'NSLocalizedString',
    r'//',   # 주석
    r'LocalizedStringKey',  # 이미 key
]


def is_skip_line(line: str) -> bool:
    """이 줄이 로그/주석이면 건너뛰기"""
    stripped = line.strip()
    if not stripped or stripped.startswith('//'):
        return True
    for pat in SKIP_PATTERNS:
        # AppLogger.log(.general, "... 한글 ...") 같은 형태는 건너뛰기
        if re.search(pat, stripped):
            return True
    return False


def extract_strings_from_file(filepath: Path):
    """파일 하나에서 한글 포함 사용자 대면 문자열 추출"""
    strings = set()
    try:
        with open(filepath, 'r', encoding='utf-8') as f:
            content = f.read()
    except Exception as e:
        print(f"⚠️  읽기 실패: {filepath} — {e}", file=sys.stderr)
        return strings

    # 라인 단위로 처리해서 주석/로그 라인 건너뛰기
    for line in content.split('\n'):
        if is_skip_line(line):
            continue

        for pat in AUTO_LOCALIZED_PATTERNS:
            matches = re.findall(pat, line)
            for m in matches:
                # 한글이 실제로 포함되어 있는지 다시 확인
                if re.search(r'[가-힣]', m):
                    # 문자열 보간 제외: "선택: \(count)장" 같은 건 그대로 포함 (Swift 가 처리)
                    strings.add(m)

    return strings


def main():
    all_strings = set()
    swift_files = list(ROOT.rglob("*.swift"))
    print(f"검색 대상: {len(swift_files)} Swift 파일")

    per_file_counts = {}
    for sf in swift_files:
        s = extract_strings_from_file(sf)
        if s:
            per_file_counts[sf.relative_to(ROOT)] = len(s)
        all_strings.update(s)

    # 정렬된 결과
    sorted_strings = sorted(all_strings)
    print(f"\n총 추출 한글 문자열: {len(sorted_strings)}개")
    print(f"\n상위 10개 파일:")
    for f, c in sorted(per_file_counts.items(), key=lambda x: -x[1])[:10]:
        print(f"  {f}: {c}개")

    # 기존 Localizable.xcstrings 읽고 병합
    if OUTPUT_XCSTRINGS.exists():
        with open(OUTPUT_XCSTRINGS, 'r', encoding='utf-8') as f:
            catalog = json.load(f)
    else:
        catalog = {"sourceLanguage": "ko", "strings": {}, "version": "1.0"}

    # 새 문자열 추가 (기존 것은 유지)
    added = 0
    for s in sorted_strings:
        if s not in catalog["strings"]:
            catalog["strings"][s] = {
                "extractionState": "manual",
                "localizations": {
                    "ko": {
                        "stringUnit": {
                            "state": "translated",
                            "value": s
                        }
                    }
                    # "en" 은 나중에 번역해서 추가
                }
            }
            added += 1

    # 저장
    with open(OUTPUT_XCSTRINGS, 'w', encoding='utf-8') as f:
        json.dump(catalog, f, ensure_ascii=False, indent=2)

    print(f"\n✅ {OUTPUT_XCSTRINGS} 에 {added}개 신규 추가")
    print(f"   총 {len(catalog['strings'])}개 키 존재")

    # 번역 대기 목록 출력 (CSV 로 저장 — 나중에 bulk 번역용)
    untranslated_csv = ROOT.parent / "scripts" / "strings_to_translate.csv"
    with open(untranslated_csv, 'w', encoding='utf-8') as f:
        f.write("key,korean,english\n")
        for s in sorted_strings:
            # CSV escape
            escaped = '"' + s.replace('"', '""') + '"'
            f.write(f"{escaped},{escaped},\n")
    print(f"\n📋 번역 대기 CSV: {untranslated_csv}")


if __name__ == "__main__":
    main()
