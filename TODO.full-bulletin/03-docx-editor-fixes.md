# 03 — Editor-side fixes for issue #4 findings 1–3 (BLOCKED on editor)

## Problem

Three findings in issue #4 require the OIML editor to update the source
`contents-of-oiml-bulletins-2023-07-24.docx`. The dataset cannot fix
these from the parser side without fabricating data.

### Finding 1 — October 2019 issue is missing entirely
No row in the docx for Volume LX Number 4 (October 2019). Either the
issue was not published, or the row was omitted by accident.

### Finding 2 — October 2020 row lacks the Volume/Number prefix
Cell1 reads `"OCTOBER 2020"` instead of `"VOLUME LXI • NUMBER 3 OCTOBER 2020"`.
The October 2020 article entries get attributed to July 2020 by any
consumer that relies on the Volume/Number prefix.

### Finding 3 — 2019 has no year header in cell0
All three 2019 rows have an empty Year column. Consumers that use cell0
for year attribution silently roll 2019 entries into 2018.

## Solution

Route issue #4 to the OIML editor with a request to:

1. **Confirm whether October 2019 was published.** If yes, add its row
   with the article list. If no, note that explicitly in the docx.
2. **Replace `"OCTOBER 2020"`** with `"VOLUME LXI • NUMBER 3 OCTOBER 2020"`
   in the October 2020 row's cell1.
3. **Add `2019`** to cell0 of the first 2019 row.

After the editorshipips a refreshed docx, re-run:

```bash
cp <new-docx> backfill/cache/contents-of-oiml-bulletins-2023-07-24.docx
bundle exec ruby backfill/docx_contents.rb
bundle exec ruby backfill/load_to_data.rb
```

## Workaround (interim)

TODO 05 (GLM OCR of scanned-era PDFs) will pick up October 2019 and
October 2020 from the actual published PDFs, since the docx cannot be
trusted for those issues. The dataset will reflect what's actually
published; the docx gap is documented for the editor.

## Acceptance

- Editor confirms the three findings are addressed in a refreshed docx
- Re-running the loader produces correct 2019 (4 issues), 2020 (4
  issues), and October 2019 records
- No record carries `note.type: source` warning about missing year header
