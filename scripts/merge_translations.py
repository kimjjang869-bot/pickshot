#!/usr/bin/env python3
"""
번역된 CSV 3개를 합쳐서 Localizable.xcstrings 의 en localization 에 반영.
"""

import csv
import json
import sys
from pathlib import Path

ROOT = Path("/Users/potokan/PhotoRawManager/PhotoRawManager")
XCSTRINGS = ROOT / "Localizable.xcstrings"

csv_files = [f"/tmp/pickshot_trans_{i}.csv" for i in (1, 2, 3)]

# 기존 xcstrings 로드
with open(XCSTRINGS, 'r', encoding='utf-8') as f:
    catalog = json.load(f)

# 모든 CSV 의 한글 → 영어 맵 구축
translations = {}
total_csv_rows = 0
for csv_path in csv_files:
    with open(csv_path, 'r', encoding='utf-8') as f:
        reader = csv.reader(f)
        next(reader)  # header
        for row in reader:
            if len(row) < 3: continue
            key, korean, english = row[0], row[1], row[2]
            if english.strip():
                translations[korean] = english.strip()
                total_csv_rows += 1

print(f"CSV 에서 읽은 번역: {total_csv_rows}개 (unique {len(translations)}개)")

# xcstrings 에 en 로컬라이제이션 추가
added = 0
missing = 0
for key, entry in catalog["strings"].items():
    if "localizations" not in entry:
        entry["localizations"] = {}

    if key in translations:
        entry["localizations"]["en"] = {
            "stringUnit": {
                "state": "translated",
                "value": translations[key]
            }
        }
        added += 1
    else:
        missing += 1

# 저장
with open(XCSTRINGS, 'w', encoding='utf-8') as f:
    json.dump(catalog, f, ensure_ascii=False, indent=2)

print(f"✅ {added}개 키에 영어 번역 반영")
if missing:
    print(f"⚠️  {missing}개 키는 번역 누락 (CSV 에 없음)")
print(f"총 xcstrings 키: {len(catalog['strings'])}")
