#!/usr/bin/env python3
"""Write XiaoYuNote update metadata files for released installers."""

from __future__ import annotations

import argparse
import json
from datetime import datetime
from email.utils import format_datetime
from pathlib import Path
from zoneinfo import ZoneInfo
import xml.etree.ElementTree as ET


SPARKLE_NS = "http://www.andymatuschak.org/xml-namespaces/sparkle"


def write_json(path: Path, *, version: str, change_time: str, download_url: str) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(
        json.dumps(
            {
                "version": version,
                "change_time": change_time,
                "download_url": download_url,
            },
            ensure_ascii=False,
            indent=2,
        )
        + "\n",
        encoding="utf-8",
    )


def read_signature_file(path: Path) -> dict[str, str]:
    data = json.loads(path.read_text(encoding="utf-8"))
    if not isinstance(data, dict):
        raise SystemExit(f"{path} must contain a JSON object")
    return {str(key): str(value) for key, value in data.items()}


def write_appcast(
    path: Path,
    *,
    version: str,
    pub_date: datetime,
    release_notes_url: str,
    macos_url: str,
    macos_signature: str,
    macos_length: str,
) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)

    ET.register_namespace("sparkle", SPARKLE_NS)
    root = ET.Element("rss", {"version": "2.0"})
    channel = ET.SubElement(root, "channel")
    ET.SubElement(channel, "title").text = "XiaoYuNote Updates"
    ET.SubElement(channel, "description").text = "XiaoYuNote desktop app updates"
    ET.SubElement(channel, "language").text = "zh-CN"

    item = ET.SubElement(channel, "item")
    ET.SubElement(item, "title").text = f"XiaoYuNote v{version}"
    ET.SubElement(item, f"{{{SPARKLE_NS}}}version").text = version
    ET.SubElement(item, f"{{{SPARKLE_NS}}}shortVersionString").text = version
    ET.SubElement(item, f"{{{SPARKLE_NS}}}releaseNotesLink").text = (
        release_notes_url
    )
    ET.SubElement(item, "pubDate").text = format_datetime(pub_date)
    ET.SubElement(
        item,
        "enclosure",
        {
            "url": macos_url,
            f"{{{SPARKLE_NS}}}edSignature": macos_signature,
            f"{{{SPARKLE_NS}}}os": "macos",
            "length": macos_length,
            "type": "application/octet-stream",
        },
    )

    tree = ET.ElementTree(root)
    ET.indent(tree, space="  ")
    tree.write(path, encoding="utf-8", xml_declaration=True)


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("--version", required=True)
    parser.add_argument("--repo", required=True)
    parser.add_argument("--macos-asset", required=True)
    parser.add_argument("--windows-asset", required=True)
    parser.add_argument("--notes", type=Path, required=True)
    parser.add_argument("--output-dir", type=Path, required=True)
    parser.add_argument("--macos-signature-file", type=Path, required=True)
    parser.add_argument("--change-time", default="")
    args = parser.parse_args()

    now = datetime.now(ZoneInfo("Asia/Shanghai"))
    change_time = args.change_time.strip()
    if not change_time:
        change_time = (
            f"{now.year}年{now.month}月{now.day}日 "
            f"{now.hour:02d}:{now.minute:02d}:{now.second:02d}"
        )

    release_base = f"https://github.com/{args.repo}/releases/download/{args.version}"
    macos_url = f"{release_base}/{args.macos_asset}"
    windows_url = f"{release_base}/{args.windows_asset}"
    write_json(
        args.output_dir / "mac.json",
        version=args.version,
        change_time=change_time,
        download_url=macos_url,
    )
    write_json(
        args.output_dir / "windows.json",
        version=args.version,
        change_time=change_time,
        download_url=windows_url,
    )

    changelog = args.notes.read_text(encoding="utf-8").strip()
    if not changelog:
        raise SystemExit("Release notes are empty")
    args.output_dir.mkdir(parents=True, exist_ok=True)
    args.output_dir.joinpath("LATESTCHANGELOG.md").write_text(
        "## ✨ 更新日志\n\n" + changelog + "\n",
        encoding="utf-8",
    )
    macos_signature = read_signature_file(args.macos_signature_file)
    release_notes_url = f"{release_base}/LATESTCHANGELOG.md"
    write_appcast(
        args.output_dir / "appcast.xml",
        version=args.version,
        pub_date=now,
        release_notes_url=release_notes_url,
        macos_url=macos_url,
        macos_signature=macos_signature.get("edSignature", ""),
        macos_length=macos_signature.get("length", ""),
    )


if __name__ == "__main__":
    main()
