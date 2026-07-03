# 04 — Born-digital PDF text extraction (2000–2024)

## Problem

For ~100 born-digital Bulletin PDFs (2000–2024), the docx spine gives
title + (sometimes) author but **no page numbers** and no second source
for verification. All 3737 docx-spine records remain single-source
(`ext.provenance: [docx]`).

The born-digital PDFs have a clean text layer that yields:

- Article start pages (from the printed SOMMAIRE)
- Authors the docx missed (e.g. separate-line bylines)
- A second source so records can pass the ≥2-source auto-accept rule

## Solution

Write `backfill/extract_born_digital.rb` — a one-off script that:

1. Reads `backfill/cache/pdf_index.yaml` for the 246 indexed PDFs
2. For each born-digital PDF (filter by year ≥ 2000, file size < 50MB):
   - Download to `backfill/cache/pdfs/<filename>.pdf`
   - Run `pdftotext -layout` (poppler) — fast, no API cost
   - Parse the SOMMAIRE / Contents page (typically pages 2-3) to extract:
     - article title (normalized)
     - author + affiliation
     - start page (and end page = next article's start - 1)
3. Reconcile against existing `data/bulletin_<year>-<issue>-*.yaml` records:
   - Match by normalized title similarity
   - Patch in `extent.locality.page` (start/end) where missing
   - Patch in `contributor.person` author where missing and OCR-confident
   - Flip `ext.provenance` from `[docx]` to `[docx, pdf]`
   - Where docx is missing the article entirely (e.g. 1980 no.80 case),
     emit a new article record

## Scope

- ~100 born-digital PDFs (2000–2024, excluding the 5 in TODO 02 which
      are processed separately)
- ~25 years × ~4 issues × ~10 articles = ~1000 articles enriched
- Target: ~80% of records become 2-source; pages field populated for
  the same ~80%

## Acceptance

- Script runs end-to-end without manual intervention
- Caches each PDF's extracted text and parsed SOMMAIRE so re-runs are
  free
- New records pass `check_data.rb` round-trip
- A reconciliation summary shows: # records enriched with pages, #
  records enriched with authors, # records auto-promoted to
  `provenance: [docx, pdf]`
- No regression in existing HTML-era records
