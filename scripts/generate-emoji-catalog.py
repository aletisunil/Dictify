#!/usr/bin/env python3
"""Generate Dictify's spoken-emoji catalog from Unicode emoji-test.txt.

The checked-in catalog is pinned to Emoji 15.0, the repertoire available on
Dictify's minimum deployment target (macOS 14.0). Download the source file from
https://unicode.org/Public/emoji/15.0/emoji-test.txt, then run:

    python3 scripts/generate-emoji-catalog.py \
        --input /path/to/emoji-test.txt \
        --output Dictify/Resources/emoji-catalog.json

The generator keeps fully-qualified base forms, removes skin-tone and gendered
combinations, keeps neutral equivalents, and adds natural country-flag aliases.
"""

from __future__ import annotations

import argparse
import json
import re
from pathlib import Path


CATALOG_VERSION = "15.0"
SOURCE_URL = "https://unicode.org/Public/emoji/15.0/emoji-test.txt"
LICENSE_URL = "https://www.unicode.org/license.txt"
SKIN_TONES = set(range(0x1F3FB, 0x1F400))
GENDER_SIGNS = {0x2640, 0x2642}
REGIONAL_INDICATOR_START = 0x1F1E6
REGIONAL_INDICATOR_END = 0x1F1FF


def normalized_words(value: str) -> tuple[str, ...]:
    # Match the Swift runtime's Unicode letter/number tokenization closely.
    return tuple(re.findall(r"[^\W_]+", value.casefold(), flags=re.UNICODE))


def is_gender_or_family_variant(codepoints: list[int], name: str) -> bool:
    lowered = name.casefold()

    if 0x200D in codepoints and any(cp in GENDER_SIGNS for cp in codepoints):
        return True

    # Gendered people/role sequences are omitted in favor of their neutral
    # "person ..." entry. Standalone "man" and "woman" remain available.
    gendered_prefixes = ("woman ", "man ", "women ", "men ")
    if lowered.startswith(gendered_prefixes):
        return True
    if lowered in {"pregnant woman", "pregnant man"}:
        return True

    # Keep the generic family/couple/kiss glyph, but omit detailed combinations.
    if lowered.startswith(("family:", "couple with heart:", "kiss:")):
        return True

    return False


def flag_aliases(codepoints: list[int], name: str) -> list[str]:
    if not name.casefold().startswith("flag:"):
        return []

    region_name = spoken_name(name.split(":", 1)[1].strip())
    region_name = re.sub(r"\bSt\.\s+", "Saint ", region_name)
    region_name = region_name.replace("U.S.", "US")
    aliases = [f"{region_name} flag"]

    if (
        len(codepoints) == 2
        and all(REGIONAL_INDICATOR_START <= cp <= REGIONAL_INDICATOR_END for cp in codepoints)
    ):
        region_code = "".join(chr(ord("A") + cp - REGIONAL_INDICATOR_START) for cp in codepoints)
        aliases.append(f"{region_code} flag")

    if region_name == "United States":
        aliases.extend(["USA flag", "American flag"])
    elif region_name == "United Kingdom":
        aliases.extend(["UK flag", "Great Britain flag", "British flag"])

    return aliases


def spoken_name(name: str) -> str:
    """Convert CLDR punctuation into words that can actually be dictated."""
    special_names = {
        "keycap: #": "number sign keycap",
        "keycap: *": "asterisk keycap",
    }
    return special_names.get(name, name.replace(":", " ").replace("&", "and"))


def parse_catalog(source: str) -> list[dict[str, object]]:
    if f"# Version: {CATALOG_VERSION}" not in source:
        raise ValueError(f"Expected Unicode Emoji {CATALOG_VERSION} source data")

    entries: list[dict[str, object]] = []
    cue_owners: dict[tuple[str, ...], str] = {}

    for raw_line in source.splitlines():
        if "; fully-qualified" not in raw_line or "#" not in raw_line:
            continue

        codepoint_text, remainder = raw_line.split(";", 1)
        status, description = remainder.split("#", 1)
        if status.strip() != "fully-qualified":
            continue

        match = re.match(r"\s*(\S+)\s+E[0-9.]+\s+(.+?)\s*$", description)
        if not match:
            raise ValueError(f"Could not parse emoji description: {raw_line}")

        emoji, name = match.groups()
        codepoints = [int(value, 16) for value in codepoint_text.split()]
        if any(cp in SKIN_TONES for cp in codepoints):
            continue
        if is_gender_or_family_variant(codepoints, name):
            continue

        names = [spoken_name(name)]
        names.extend(flag_aliases(codepoints, name))
        deduplicated_names: list[str] = []
        local_keys: set[tuple[str, ...]] = set()
        for cue in names:
            key = normalized_words(cue)
            if not key or key in local_keys:
                continue
            local_keys.add(key)
            owner = cue_owners.get(key)
            if owner is not None and owner != emoji:
                raise ValueError(f"Duplicate spoken cue {cue!r}: {owner} and {emoji}")
            cue_owners[key] = emoji
            deduplicated_names.append(cue)

        entries.append({"emoji": emoji, "names": deduplicated_names})

    if not entries:
        raise ValueError("No emoji entries were generated")
    return entries


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("--input", required=True, type=Path)
    parser.add_argument("--output", required=True, type=Path)
    args = parser.parse_args()

    entries = parse_catalog(args.input.read_text(encoding="utf-8"))
    document = {
        "version": CATALOG_VERSION,
        "source": SOURCE_URL,
        "license": LICENSE_URL,
        "entries": entries,
    }
    args.output.parent.mkdir(parents=True, exist_ok=True)
    args.output.write_text(
        json.dumps(document, ensure_ascii=False, indent=2, sort_keys=False) + "\n",
        encoding="utf-8",
    )
    print(f"Generated {len(entries)} emoji entries at {args.output}")


if __name__ == "__main__":
    main()
