"""Report compressed IPA size, installed payload and its largest components."""
import argparse
import json
from pathlib import Path
import zipfile


def report(path):
    with zipfile.ZipFile(path) as archive:
        entries = [entry for entry in archive.infolist()
                   if entry.filename.startswith("Payload/") and not entry.is_dir()]
        if not entries or not any(".app/" in entry.filename for entry in entries):
            raise ValueError("IPA has no application payload")
        return {
            "ipa_bytes": path.stat().st_size,
            "payload_bytes": sum(entry.file_size for entry in entries),
            "largest_files": [
                {"path": entry.filename, "bytes": entry.file_size}
                for entry in sorted(entries, key=lambda entry: entry.file_size, reverse=True)[:15]
            ],
        }


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("ipa", type=Path)
    parser.add_argument("--output", type=Path, required=True)
    args = parser.parse_args()
    result = report(args.ipa)
    args.output.write_text(json.dumps(result, indent=2) + "\n")
    summary = (f"IPA: {result['ipa_bytes'] / 1_000_000:.1f} MB; "
               f"uncompressed payload: {result['payload_bytes'] / 1_000_000:.1f} MB")
    print(summary)
    print("Largest payload files:")
    for entry in result["largest_files"]:
        print(f"  {entry['bytes'] / 1_000_000:.1f} MB  {entry['path']}")
    import os
    if os.environ.get("GITHUB_STEP_SUMMARY"):
        with open(os.environ["GITHUB_STEP_SUMMARY"], "a") as stream:
            stream.write(f"\n{summary}\n")


if __name__ == "__main__":
    main()
