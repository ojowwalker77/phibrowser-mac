#!/usr/bin/env python3
"""Generate the bundled emoji catalog from Unicode emoji-test.txt."""

from __future__ import annotations

import argparse
import json
import re
import sys
import urllib.request
from dataclasses import dataclass
from pathlib import Path


DEFAULT_SOURCE_URL = "https://unicode.org/Public/emoji/latest/emoji-test.txt"
SKIN_TONE_CODEPOINTS = {"1F3FB", "1F3FC", "1F3FD", "1F3FE", "1F3FF"}


@dataclass(frozen=True)
class EmojiRecord:
    codepoints: tuple[str, ...]
    text: str
    name: str
    group: str
    subgroup: str
    order: int

    @property
    def id(self) -> str:
        return "-".join(self.codepoints)

    @property
    def has_skin_tone(self) -> bool:
        return any(codepoint in SKIN_TONE_CODEPOINTS for codepoint in self.codepoints)

    @property
    def base_codepoints(self) -> tuple[str, ...]:
        return tuple(codepoint for codepoint in self.codepoints if codepoint not in SKIN_TONE_CODEPOINTS)

    def variant_payload(self) -> dict[str, str]:
        return {
            "id": self.id,
            "text": self.text,
            "name": self.name,
        }


def read_source(source: str) -> str:
    if source.startswith("http://") or source.startswith("https://"):
        with urllib.request.urlopen(source, timeout=30) as response:
            return response.read().decode("utf-8")
    return Path(source).read_text(encoding="utf-8")


def parse_emoji_test(source_text: str) -> tuple[str, str, list[EmojiRecord]]:
    version = ""
    date = ""
    group = ""
    subgroup = ""
    records: list[EmojiRecord] = []

    line_pattern = re.compile(
        r"^(?P<codepoints>[0-9A-F ]+)\s*;\s*fully-qualified\s*#\s*"
        r"(?P<emoji>\S+)\s+E[0-9.]+\s+(?P<name>.+)$"
    )

    for line in source_text.splitlines():
        if line.startswith("# Version:"):
            version = line.split(":", 1)[1].strip()
            continue
        if line.startswith("# Date:"):
            date = line.split(":", 1)[1].strip()
            continue
        if line.startswith("# group:"):
            group = line.split(":", 1)[1].strip()
            continue
        if line.startswith("# subgroup:"):
            subgroup = line.split(":", 1)[1].strip()
            continue

        match = line_pattern.match(line)
        if not match:
            continue

        codepoints = tuple(match.group("codepoints").split())
        records.append(
            EmojiRecord(
                codepoints=codepoints,
                text=match.group("emoji"),
                name=match.group("name").strip(),
                group=group,
                subgroup=subgroup,
                order=len(records),
            )
        )

    return version, date, records


def build_catalog(version: str, date: str, source: str, records: list[EmojiRecord]) -> dict:
    base_records = [record for record in records if not record.has_skin_tone]
    variants_by_base: dict[tuple[str, ...], list[EmojiRecord]] = {}
    base_keys = {record.codepoints for record in base_records}

    for record in records:
        if not record.has_skin_tone:
            continue
        if record.base_codepoints in base_keys:
            variants_by_base.setdefault(record.base_codepoints, []).append(record)

    groups: list[dict] = []
    group_lookup: dict[str, dict] = {}

    for record in base_records:
        group_payload = group_lookup.get(record.group)
        if group_payload is None:
            group_payload = {
                "name": record.group,
                "items": [],
            }
            group_lookup[record.group] = group_payload
            groups.append(group_payload)

        group_payload["items"].append(
            {
                "id": record.id,
                "text": record.text,
                "name": record.name,
                "subgroup": record.subgroup,
                "skinVariants": [
                    variant.variant_payload()
                    for variant in variants_by_base.get(record.codepoints, [])
                ],
            }
        )

    return {
        "version": version,
        "date": date,
        "source": source,
        "groups": groups,
    }


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument(
        "--source",
        default=DEFAULT_SOURCE_URL,
        help="emoji-test.txt URL or local path",
    )
    parser.add_argument(
        "--output",
        default="Resources/Emoji/emoji-catalog.json",
        help="Output JSON path",
    )
    args = parser.parse_args()

    source_text = read_source(args.source)
    version, date, records = parse_emoji_test(source_text)
    if not records:
        print("No fully-qualified emoji records found", file=sys.stderr)
        return 1

    output_path = Path(args.output)
    output_path.parent.mkdir(parents=True, exist_ok=True)
    catalog = build_catalog(version, date, args.source, records)
    output_path.write_text(
        json.dumps(catalog, ensure_ascii=False, indent=2, sort_keys=False) + "\n",
        encoding="utf-8",
    )

    item_count = sum(len(group["items"]) for group in catalog["groups"])
    variant_count = sum(
        len(item["skinVariants"])
        for group in catalog["groups"]
        for item in group["items"]
    )
    print(
        f"Wrote {output_path} with {item_count} emoji and "
        f"{variant_count} skin variants from Emoji {version}"
    )
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
