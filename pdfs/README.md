# `pdfs/` — local cache of OIML source PDFs

Gitignored. Populated by `bundle exec oiml-fetch --pdfs`. Mirrors the
`data/*.yaml` filenames so any item's source PDF is one lookup away.

## Layout

```
pdfs/
  <ref>_<year>/              work directory (matches data/<ref>_<year>.yaml)
    <original-name>.pdf      wrapper PDFs and single-document PDFs
    parts_<lang>/            only present for PDF Portfolio collections
      <original-name>.pdf    parts extracted from the portfolio
  <ref>_<year>_<lang>/       translation directory (matches data/<...>.yaml)
    <original-name>.pdf
```

`<lang>` is the ISO 639-3 code (`eng`, `fra`, `deu`, …).

## Examples

### Portfolio collection (multi-part)

`r35_2007/` — R 35:2007 is published as a PDF Portfolio containing parts
1, 2, 3 and an amendment to part 1:

```
pdfs/r35_2007/
  r035-p-e07.pdf             # English portfolio wrapper (1.2 MB)
  r035-p-f07.pdf             # French portfolio wrapper
  parts_eng/
    r035-1-e07.pdf           # Part 1, 2007
    r035-1_amend-e14.pdf     # Part 1 Amendment, 2014
    r035-2-e11.pdf           # Part 2, 2011
    r035-3-e11.pdf           # Part 3, 2011
  parts_fra/
    r035-1-f07.pdf
    ...
```

### Single-PDF publication (no portfolio)

`r7_1979/` — R 7:1979 has separate EN and FR single PDFs, no portfolio:

```
pdfs/r7_1979/
  r007-e79.pdf               # English
  r007-f78.pdf               # French
```

No `parts_*/` directories — there's nothing to extract.

### Bilingual single-PDF

`v1_2022/` — V 1:2022 (VIML vocabulary) is one bilingual PDF:

```
pdfs/v1_2022/
  v001-ef22.pdf
```

### Translation

`r35-1-2007_deu/` — German translation of R 35-1:2007:

```
pdfs/r35-1-2007_deu/
  r035-1-de-07.pdf
```

## Portfolio detection

The fetcher uses a filename heuristic: OIML URLs containing `-p-`
(e.g. `r035-p-e07.pdf`) are PDF Portfolio wrappers. The basename
distinguishes portfolios from single-PDF editions — confirmed against the
~34 portfolio URLs currently in the dataset.

## Extraction tooling

Portfolio extraction uses Python's `pypdf` library — Ruby's PDF gems
(`origami`, `pdf-reader`) either don't support portfolios or are
incompatible with current Ruby. The fetcher shells out to a small Python
helper at `bin/extract_portfolio.py`.
