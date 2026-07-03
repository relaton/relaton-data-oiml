#!/usr/bin/env python3
"""Extract attachments and/or URI-link annotations from a PDF.

Two modes of part discovery are supported:

  1. PDF Portfolio attachments — embedded files inside the PDF.
  2. "Cover/index" PDFs — single-page documents whose /Link annotations
     point to separate part PDFs via URI actions.

Usage:
    extract_portfolio.py <pdf>                # list as JSON
    extract_portfolio.py <pdf> <out_dir>      # list + write attachments

JSON output (stdout):
    {
      "attachments": [{"name": "R035-1-e07.pdf", "size": 278756}, ...],
      "links":       [{"uri": "https://www.oiml.org/.../r049-1-e24.pdf"}, ...],
      "count":       <attachments + links>
    }
"""

import json
import sys
from pathlib import Path
from urllib.parse import urlparse

from pypdf import PdfReader


def _attachment_bytes(entry):
    if isinstance(entry, list):
        entry = entry[0] if entry else None
    if isinstance(entry, dict):
        entry = entry.get("content", entry.get("data", b""))
    if isinstance(entry, (bytes, bytearray)):
        return bytes(entry)
    return None


def extract_attachments(reader):
    items = []
    try:
        names = list(reader.attachments.keys())
    except Exception:
        return items
    for name in sorted(names):
        data = _attachment_bytes(reader.attachments[name])
        if data is None:
            continue
        items.append({"name": name, "size": len(data)})
    return items


def extract_link_uris(reader):
    """Walk all pages and collect URI annotations.

    Returns a list of {"uri": ...} dicts (deduped, preserving order).
    """
    seen = set()
    out = []
    for page in reader.pages:
        annots = page.get("/Annots")
        if not annots:
            continue
        try:
            annots = annots.get_object()
        except AttributeError:
            pass
        try:
            iterator = iter(annots)
        except TypeError:
            continue
        for ref in iterator:
            try:
                obj = ref.get_object()
            except AttributeError:
                obj = ref
            if obj.get("/Subtype") != "/Link":
                continue
            action = obj.get("/A")
            if action:
                try:
                    action = action.get_object()
                except AttributeError:
                    pass
                uri = action.get("/URI") if isinstance(action, dict) else None
            else:
                uri = obj.get("/URI")
            if not uri:
                continue
            uri = str(uri)
            if uri in seen:
                continue
            # filter to pdf part links only (avoid TOC / external noise)
            parsed = urlparse(uri)
            if parsed.path and parsed.path.lower().endswith(".pdf"):
                seen.add(uri)
                out.append({"uri": uri})
    return out


def write_attachments(reader, out_dir):
    out_dir = Path(out_dir)
    out_dir.mkdir(parents=True, exist_ok=True)
    written = []
    try:
        names = list(reader.attachments.keys())
    except Exception:
        names = []
    for name in sorted(names):
        data = _attachment_bytes(reader.attachments[name])
        if data is None:
            continue
        target = out_dir / name
        target.write_bytes(data)
        written.append(name)
    return written


def extract(pdf_path: str, out_dir: str | None = None) -> dict:
    reader = PdfReader(pdf_path)
    attachments = extract_attachments(reader)
    links = extract_link_uris(reader)
    if out_dir and attachments:
        write_attachments(reader, out_dir)
    return {
        "attachments": attachments,
        "links": links,
        "count": len(attachments) + len(links),
    }


def main() -> int:
    if len(sys.argv) < 2:
        print("usage: extract_portfolio.py <pdf> [out_dir]", file=sys.stderr)
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
