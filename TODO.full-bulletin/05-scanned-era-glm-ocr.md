# 05 — GLM OCR of scanned Bulletin PDFs (1960–1999)

## Problem

For ~150 scanned Bulletin PDFs (1960–1999, French-primary era), the
docx spine is the only source and has known gaps:

- No page numbers anywhere
- ~18% author coverage (early French bylines missed by regex)
- 1980 no.80 has 11 entries not in printed SOMMAIRE (policy needed in TODO 06)
- Bulletin no.30 and no.69 may be missing entirely (issue #4 finding 8)
- October 2019 missing, October 2020 malformed (TODO 03)

GLM OCR of the actual published Bulletins provides an independent
ground truth that fixes all of the above.

## Solution

Write `backfill/ocr_scanned_era.rb` — a one-off script that:

1. Reads `backfill/cache/pdf_index.yaml`, filters to scanned-era PDFs
   (year < 2000). Roughly 150 PDFs.
2. For each PDF:
   - Download to `~/src/oimlsmart/bulletin-data/<year>/<issue>/<filename>.pdf`
     (see "Output side" below)
   - Run GLM OCR via the existing `BulletinBackfill::GlmOcr` client,
     chunked at 30 pages per request
   - Save full markdown to the same issue folder
   - Save the GLM JSON (layout_details, usage) alongside
3. Parse the SOMMAIRE section from the markdown:
   - Title, author (par NAME (COUNTRY)), start page
4. Reconcile against existing `data/bulletin_<year>-<issue>-*.yaml`:
   - Patch page numbers, missing authors
   - Flip provenance to `[docx, ocr]`
   - For October 2019/2020 cases, recover the correct entries directly
     from the OCR
5. For any PDF whose issue isn't in the docx at all (e.g. bulletin 30,
   69, October 2019), emit fresh article records with provenance `[ocr]`

## Output side — `~/src/oimlsmart/bulletin-data/`

Per the maintainer directive, all OCRed content lives in a sister
project at `~/src/oimlsmart/bulletin-data/` with this layout:

```
bulletin-data/
  README.adoc                       # describes the structure and source
  1960/
    01/                              # issue number within year (quarterly: 01-04)
      bulletin-1960-01.pdf           # original PDF
      ocr.md                         # GLM OCR markdown
      ocr.json                       # raw GLM API response (layout_details, usage)
    02/
      ...
  1961/
    01/
      ...
```

Issue numbers are within-year (01-04). Pre-1994 cumulative-era
Bulletins map to within-year issues by position (see
`load_to_data.rb#assign_within_year_issue_no`).

## Scope

- ~150 scanned PDFs × 2-3 chunks each = ~400 GLM OCR requests
- Estimated tokens: ~30M (cached per chunk, resumable)
- Wall time: ~5-10 hours (rate-limited sequencing)
- Target: ~1500 articles gain page numbers + authors; October 2019/2020
  and any missing issues get recovered

## Acceptance

- All scanned-era PDFs downloaded and OCRed
- Output tree at `~/src/oimlsmart/bulletin-data/` matches the layout above
- README.adoc explains the structure and lists source URLs
- Records in `data/` updated with pages + authors + `provenance: [docx, ocr]`
- `check_data.rb` round-trip still passes
