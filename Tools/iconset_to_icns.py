#!/usr/bin/env python3
"""Package the PNG sizes from an .iconset directory into a legacy ICNS file.

This writes standard ICNS chunks directly. Some Command Line Tools releases
can decode iconsets but fail to encode them with iconutil.
"""

from __future__ import annotations

import struct
import sys
from pathlib import Path


def main() -> None:
    if len(sys.argv) != 3:
        raise SystemExit("usage: iconset_to_icns.py INPUT.iconset OUTPUT.icns")

    iconset = Path(sys.argv[1])
    output = Path(sys.argv[2])
    # Standard single-image and Retina ICNS chunks. The duplicate dimensions
    # are intentional: ICNS uses separate chunk IDs for the two pixel scales.
    chunks = [
        ("icp4", "icon_16x16.png"),
        ("icp5", "icon_32x32.png"),
        ("icp6", "icon_32x32@2x.png"),
        ("ic07", "icon_128x128.png"),
        ("ic08", "icon_256x256.png"),
        ("ic09", "icon_512x512.png"),
        ("ic10", "icon_512x512@2x.png"),
        ("ic11", "icon_16x16@2x.png"),
        ("ic12", "icon_32x32@2x.png"),
        ("ic13", "icon_128x128@2x.png"),
        ("ic14", "icon_256x256@2x.png"),
    ]

    payload = bytearray()
    for chunk_name, filename in chunks:
        data = (iconset / filename).read_bytes()
        if not data.startswith(b"\x89PNG\r\n\x1a\n"):
            raise ValueError(f"{filename} is not a PNG image")
        payload.extend(chunk_name.encode("ascii"))
        payload.extend(struct.pack(">I", len(data) + 8))
        payload.extend(data)

    output.parent.mkdir(parents=True, exist_ok=True)
    output.write_bytes(b"icns" + struct.pack(">I", len(payload) + 8) + payload)


if __name__ == "__main__":
    main()
