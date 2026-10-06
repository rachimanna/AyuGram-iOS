#!/usr/bin/env python3
"""Report compressed IPA and installed app bytes without counting ZIP overhead as app content."""
import argparse
import json
from pathlib import Path
from zipfile import ZipFile


def measure(path, target_mb=70):
    with ZipFile(path) as archive:
        entries = [entry for entry in archive.infolist() if entry.filename.startswith("Payload/") and not entry.is_dir()]
        installed = sum(entry.file_size for entry in entries)
        largest = sorted(entries, key=lambda entry: entry.file_size, reverse=True)[:10]
    compressed = Path(path).stat().st_size
    return {
        "ipa_bytes": compressed,
        "ipa_mb": round(compressed / 1_000_000, 2),
        "installed_app_bytes": installed,
        "installed_app_mb": round(installed / 1_000_000, 2),
        "target_ipa_mb": target_mb,
        "within_ipa_target": compressed <= target_mb * 1_000_000,
        "largest_files": [{"path": entry.filename, "mb": round(entry.file_size / 1_000_000, 2)} for entry in largest],
        "note": "Installed data, Telegram cache and signing changes are not included. A target is not a guaranteed size.",
    }


if __name__ == "__main__":
    parser = argparse.ArgumentParser()
    parser.add_argument("ipa")
    parser.add_argument("--output", default="AyuGram-size-report.json")
    args = parser.parse_args()
    report = measure(args.ipa)
    Path(args.output).write_text(json.dumps(report, indent=2) + "\n")
    print(f"IPA: {report['ipa_mb']} MB; installed app: {report['installed_app_mb']} MB; 70 MB IPA target: {'met' if report['within_ipa_target'] else 'exceeded'}")
