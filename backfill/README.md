# OIML Bulletin backfill (one-off)

**These scripts are one-off.** They are not in `lib/`, not loaded by the
gem, not in CI, and not in the daily cron. They exist to seed Bulletin
article records for the historical eras (1960 → mid-2024) that the
maintained HTML fetcher cannot reach.

Once the historical data is loaded into `data/`, these scripts can be
archived.

## Sources

| Era | Source | Notes |
|------|--------|-------|
| 2025-02 → present | HTML editions | Maintained path: `bundle exec oiml-fetch bulletin` |
| ~2000s → 2024 | Born-digital PDFs | `pdf_index.rb` lists them; GLM-OCR (`glm_ocr.rb`) or `pdftotext` extracts text |
| 1960 → ~1990s | Scanned PDFs | GLM-OCR required; French-only in early decades |
| 1960 → mid-2023 | contents-of-oiml-bulletins-2023-07-24.docx | Completeness spine; 3737 entries with title+author+country |

## Workflow

Run in this order. Each step caches its output in `backfill/cache/` so
re-runs are free.

```bash
# 1. Place the contents docx (provided by the editor) under backfill/cache/.
cp /path/to/contents-of-oiml-bulletins-2023-07-24.docx backfill/cache/

# 2. Parse the docx spine into per-entry candidates.
bundle exec ruby backfill/docx_contents.rb

# 3. Scrape the PDF archive listing (246 PDFs, real hrefs — never construct).
bundle exec ruby backfill/pdf_index.rb

# 4. OCR scanned PDFs via z.ai GLM-OCR (needs ~/.zai-api-key).
Z_AI_API_KEY="$(cat ~/.zai-api-key)" \
  bundle exec ruby backfill/glm_ocr.rb <pdf_url_or_path> <num_pages>

# 5. Reconcile. Auto-accepts >=2-source agreement; queues single-source
#    candidates for human review under backfill/candidates/.
bundle exec ruby backfill/reconcile.rb
```

## Accuracy model

Per the project decision: **≥2 independent sources agreeing on title**
(+author where present) → auto-accept into `data/`. Single-source or
conflicting → `backfill/candidates/<year>-<issue>-<seq>.yaml` carrying
`ext.provenance` and `ext.review: pending` for human review.

The docx is the **completeness spine** — it lists every entry that
should exist (1960–mid-2023). Any docx entry with no PDF/HTML match
stays in review; any PDF/HTML article absent from the docx is flagged.

## GLM-OCR specifics

Endpoint: `POST https://api.z.ai/api/paas/v4/layout_parsing`,
`Authorization: Bearer $Z_AI_API_KEY`. Limits: PDF ≤ 50 MB, ≤ 30 pages
per request — `glm_ocr.rb` chunks 30-page windows and concatenates the
`md_results`. Each chunk is cached by SHA-256(url|window) so restarts
resume for free. Token `usage` is logged per call.

OIML PDFs are public URLs — pass them directly as the `file` field; no
need to download/base64 unless working from a local copy.

## Output shape

Candidates match the maintained bulletin record shape exactly:
`type: article`, `series: OIML Bulletin`, `extent.locality: volume/issue`,
`relation: includedIn` the issue. Promoting a candidate to `data/` is a
file move plus a `bulletin_<year>.yaml` / `bulletin_<year>-<issue>.yaml`
update to add the `hasPart` relation.
