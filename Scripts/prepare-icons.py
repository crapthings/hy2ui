#!/usr/bin/env python3
"""Builds local template PDF assets from pinned IconMCP SVG sources without using the network."""

import hashlib
import json
from pathlib import Path
import shutil
import subprocess
import xml.etree.ElementTree as ET


def generate_assets(root: Path) -> None:
    """Validates pinned SVG sources and converts each one into an Xcode template image set."""
    source = root / "Design/Icons/IconMCP"
    manifest = json.loads((source / "manifest.json").read_text())
    converter = shutil.which("rsvg-convert")
    if converter is None:
        raise RuntimeError("Install librsvg to regenerate icons: brew install librsvg")
    catalog = root / "App/Assets.xcassets"
    catalog.mkdir(parents=True, exist_ok=True)
    (catalog / "Contents.json").write_text(json.dumps({"info": {"author": "xcode", "version": 1}}, indent=2) + "\n")
    allowed = {"svg", "g", "path", "line", "rect", "circle", "ellipse", "polyline", "polygon"}
    for icon in manifest["icons"]:
        svg = source / (icon["name"] + ".svg")
        if hashlib.sha256(svg.read_bytes()).hexdigest() != icon["sha256"]:
            raise ValueError(f"Pinned source hash changed: {svg.name}")
        for element in ET.fromstring(svg.read_bytes()).iter():
            if element.tag.rsplit("}", 1)[-1] not in allowed:
                raise ValueError(f"Unsupported SVG element in {svg.name}")
            if any(key.rsplit("}", 1)[-1] in {"href", "style"} or key.startswith("on") for key in element.attrib):
                raise ValueError(f"External content or scripting in {svg.name}")
        destination = catalog / ("IconMCP-" + icon["role"] + ".imageset")
        destination.mkdir(parents=True, exist_ok=True)
        subprocess.run([converter, "--format=pdf", "--dpi-x=72", "--dpi-y=72", "--output=" + str(destination / "icon.pdf"), str(svg)], check=True)
        contents = {
            "images": [{"filename": "icon.pdf", "idiom": "universal"}],
            "info": {"author": "xcode", "version": 1},
            "properties": {"preserves-vector-representation": True, "template-rendering-intent": "template"},
        }
        (destination / "Contents.json").write_text(json.dumps(contents, indent=2) + "\n")
    resources = root / "App/Resources"
    resources.mkdir(parents=True, exist_ok=True)
    shutil.copyfile(source / "LICENSE.txt", resources / "IconMCP-LICENSE.txt")
    print(f"Prepared {len(manifest['icons'])} vector template icons from pinned local sources.")


def main() -> None:
    """Resolves the repository and regenerates its checked-in icon assets."""
    generate_assets(Path(__file__).resolve().parents[1])


if __name__ == "__main__":
    main()
