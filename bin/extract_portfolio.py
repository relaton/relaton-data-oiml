#!/usr/bin/env python3
"""Extract attachments from a PDF Portfolio.

Usage:
    extract_portfolio.py <portfolio.pdf>              # list attachments as JSON
    extract_portfolio.py <portfolio.pdf> <out_dir>    # list + write files

Writes attachments to <out_dir>/<original_filename>. Outputs JSON to stdout:
    {"attachments": [{"name": "R035-1-e07.pdf", "size": 278756}, ...]}
"""

import json
import sys
from pathlib import Path

from pypdf import PdfReader


def extract(pdf_path: str, out_dir: str | None = None) -> dict:
    reader = PdfReader(pdf_path)
    attachments = []
    for name in sorted(reader.attachments):
        if not name.lower().endswith(".pdf"):
            continue
        data_list = reader.attachments[name]
        data = data_list[0] if isinstance(data_list, list) else data_list
        if isinstance(data, dict):
            data = data.get("content", data.get("data", b""))
        if not isinstance(data, (bytes, bytearray)):
            continue
        attachments.append({"name": name, "size": len(data)})
        if out_dir:
            target = Path(out_dir) / name
            target.parent.mkdir(parents=True, exist_ok=True)
            target.write_bytes(data)
    return {"attachments": attachments, "count": len(attachments)}


def main() -> int:
    if len(sys.argv) < 2:
        print("usage: extract_portfolio.py <portfolio.pdf> [out_dir]", file=sys.stderr)
        return 1
    pdf_path = sys.argv[1]
    out_dir = sys.argv[2] if len(sys.argv) > 2 else None
    try:
        result = extract(pdf_path, out_dir)
    except Exception as e:
        print(json.dumps({"error": str(e)}), file=sys.stderr)
        return 2
    print(json.dumps(result))
    return 0


if __name__ == "__main__":
    sys.exit(main())
