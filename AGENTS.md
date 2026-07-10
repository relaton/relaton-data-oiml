# AGENTS.md

Compact briefing for OpenCode sessions working in `relaton-data-oiml`.
Sibling repo of `relaton-data-iho`, `relaton-data-bipm`, `relaton-data-3gpp`
under `/Users/mulgogi/src/relaton/`.

## What this repo is

Bibliographic dataset of OIML publications (Recommendations R, Documents D,
Guides G, Vocabularies V, Basic Publications B, Expert Reports E, Seminar
Reports S) plus other-language translations, stored as Relaton YAML under
`data/`. The scraper lives in this repo (`lib/oiml_fetcher/`); data is
consumed by `relaton-bib` directly (no `relaton-oiml` gem exists yet).

## The big gotcha: oiml.org is React-rendered

The seven publication landing pages look like normal Plone HTML:

```
https://www.oiml.org/en/publications/<type>/publication_view?p_type=N&p_status=1
```

They are **NOT**. The publication list is rendered client-side by
`++resource++oiml.members/react_scripts/publication_view.js` into
`<div id="app-container">`. A plain Nokogiri/Mechanize scrape of the HTML
returns **zero entries**.

The real data is a JSON endpoint the React app calls:

```
GET https://www.oiml.org/en/publications/<type>/@@API/publications?id_type=<N>&id_status=<S>
GET https://www.oiml.org/fr/publications/<type-fr>/@@API/publications?id_type=<N>&id_status=<S>
```

Returns `{ "lang": "...", "pubtype": "OIML ...", "publications": [ ... ] }`.
Each entry:

```json
{
  "id": 497,
  "ref": "R 35-en",
  "url": "en/files/pdf_r/r035-p-e07.pdf",
  "url_en": "en/files/pdf_r/r035-p-e07.pdf",
  "fileExists": true,
  "title": "Material measures of length for general use",
  "shortTitle": "R 35:2007(en)",
  "edition": 2007,
  "edition_en": 2007,
  "idStatus": 1,
  "scUrl": "scinfo_view?idsc=56",
  "scTitle": "TC7",
  "successors": []
}
```

### `p_type` → publication type

| p_type | EN path segment  | FR path segment     | prefix | doctype             |
|--------|------------------|---------------------|--------|---------------------|
| 1      | recommendations  | recommandations     | R      | recommendation      |
| 2      | documents        | documents           | D      | document            |
| 3      | guides           | guides              | G      | guide               |
| 4      | vocabularies     | vocabulaires        | V      | vocabulary          |
| 6      | basic            | publications-base   | B      | basic-publication   |
| 7      | expert           | rapports-dexpert    | E      | expert-report       |
| 8      | seminar          | seminaire           | S      | seminar-report      |

FR segments must match Plone's actual French slugs (note: `rapports-dexpert`
no `s`, no hyphen after `d`; `seminaire` not `rapports-de-seminaires`).

### `idStatus` → lifecycle

| code | meaning    | notes                                                  |
|------|------------|--------------------------------------------------------|
| 0    | in-force   | Sentinel; appears on some older seminar entries.       |
| 1    | in-force   | Standard in-force marker (EN endpoint).                |
| 2    | in-force   | FR-endpoint-only marker for in-force French editions.  |
| 5    | superseded | Has `successors` or appears under `id_status=5`.       |
| 6    | withdrawn  | Often `fileExists: false`.                             |
| 7    | joint      | Joint publication hosted elsewhere (e.g. R 99-ISO3930).|

**All historical records are included** — the scraper iterates over
`p_status = [1, 5, 6]` for every type and keeps superseded/withdrawn entries
with their correct `status.stage` (`superseded` / `withdrawn`).

### Gotchas inside the JSON

- `ref` is locale-suffixed (`"R 35-en"`, `"R 35-fr"`), **not** a clean docid.
  Build the docid from `shortTitle` (`"R 35:2007(en)"` → `OIML R 35:2007`).
- `edition` is a **year** (Integer). Map to `date.published` and
  `version.revision_date`; leave `edition.content` empty.
- **Part numbers exist for some publications** — Basic publications (`B 6-1`,
  `B 6-2`) and some Recommendations (`R 49-1`, `R 76-1`, `R 129-1`). The
  translation pages may show part numbers (`R 35-1:2007`) even when the API
  doesn't have them as separate entries.
- `scTitle` (`TC7`, `TC18/SC2`, `BIML`, `CEEMS`) is the authoring body →
  goes into `contributor.role.description: committee` with
  `organization.subdivision`. `TC\d+/\d+` splits into TC + Subcommittee.
- `successors` is always empty in practice — no `obsoletes` relations to
  synthesize. The `idStatus` field carries the lifecycle signal.

## Work + instance model

Most OIML publications are issued as **separate** EN and FR PDFs
(`r035-p-e07.pdf` vs `r035-p-f07.pdf`) — two distinct language-specific
documents, not one bilingual work. The data model reflects this:

- **Work** (`data/r35_2007.yaml`) — abstract publication. Carries docid,
  titles in all available languages, contributor, status. **No `source`**
  (work has no PDF). Links to instances via `relation: hasInstance`.
- **Instance** (`data/r35_2007_eng.yaml`, `data/r35_2007_fra.yaml`) —
  language-specific PDF. One `source`, one `title`, one `language`.
  Links back via `relation: instanceOf`.
- **Translation** (`data/r35-1-2007_deu.yaml`) — same shape as instance,
  but `relation: translatedFrom` instead of `instanceOf`, and
  `contributor.role.type: translator`.

The bilingual case (single combined PDF, e.g. `V 1` / VIML at
`v001-ef22.pdf`) is detected by comparing PDF filenames across EN/FR
endpoints — same basename → one YAML with `language: [eng, fra]`, no split.

## Language code conventions (two distinct vocabularies)

| Where                                | Format             | Examples                          |
|--------------------------------------|--------------------|-----------------------------------|
| `docidentifier.content` suffix       | OIML publication   | `E` `F` `D` `R` `S` `C` `A` `U`   |
|                                      | codes              | `PO` `PT` `PE` `SR`               |
| `language` field, `title.language`,  | ISO 639-3          | `eng` `fra` `deu` `rus` `spa`     |
| filename `_lang` suffix              |                    | `zho` `ara` `ukr` `pol` `por`     |
|                                      |                    | `fas` `srp`                       |

OIML single-letter codes match what's printed on the publication cover
(`R 35:2007(E)`). ISO 639-3 is the relaton-bib standard for `language`.
The two maps are `OimlFetcher::DOCID_LANG_CODE` and the inverse of
`OimlFetcher::LANG_CODE` respectively.

## Identifier derivation

| Item                       | `id`              | `docidentifier.content`        |
|----------------------------|-------------------|--------------------------------|
| Work                       | `R35-2007`        | `OIML R 35:2007`               |
| EN instance                | `R35-2007-E`      | `OIML R 35:2007 (E)`           |
| FR instance                | `R35-2007-F`      | `OIML R 35:2007 (F)`           |
| German translation of pt 1 | `R35-1-2007-deu`  | `OIML R 35-1:2007 (D)`         |

`id` algorithm: strip `OIML `, strip whitespace, replace `:` with `-`.
Work-level ids never contain a language suffix. EN/FR instances append the
OIML letter code (`-E`, `-F`); translations append the ISO 639-3 code
(`-deu`).

Filename: lowercase id-ish — `<ref_lower>_<year>[_<lang>].yaml`. EN/FR
instances use ISO 639-3 (`r35_2007_eng.yaml`); translations same
(`r35-1-2007_deu.yaml`).

## OIML Bulletin articles — periodical hierarchy

### Docx vs printed TOC authority

**Policy: the editor-provided contents.docx is authoritative.** The docx
may list articles not present in a Bulletin's printed SOMMAIRE (verified
case: 1980 no.80 has 18 entries in the docx vs 7 in the printed TOC; the
other 11 are genuine articles — country reports, presidential addresses,
etc. — that the printed TOC omitted, likely for space). The dataset
intentionally includes these. Do not prune records just because they
don't appear in a printed TOC. See `TODO.full-bulletin/06-docx-vs-toc-policy.md`.

Bulletin articles (a new record class, distinct from OIML publications)
follow a four-tier containment hierarchy, mirroring how BIPM models
*Metrologia* (`series` + `extent.locality`) but with explicit container
records for navigability:

```
bulletin.yaml              — periodical    (type: journal, doctype: periodical)
  hasPart →
bulletin_2026.yaml         — volume/year   (type: journal, doctype: volume)
  hasPart →
bulletin_2026-02.yaml      — issue         (type: journal, doctype: issue)
  hasPart →
bulletin_2026-02-11.yaml   — article       (type: article, doctype: article)
```

Containment is bidirectional: `hasPart` downward, `partOf` (or
`includedIn` for articles) upward — same pattern as work/instance.

Article docid scheme: `OIML Bulletin YYYY-NN-SS` where SS is the
sequence within the issue. The HTML-era natural key is the 8-digit
oiml.org id (`20260211` = year 2026, issue 02, sequence 11) carried as
a secondary `docidentifier` of type `OIML-bulletin-url-slug`. Volume
roman numerals (`LXVII` for 2026) come from the issue page's
`VOLUME {roman} - NUMBER {n}` header link.

Quarterly date mapping: issue 1 → Jan, 2 → Apr, 3 → Jul, 4 → Oct
(`BulletinFetcher::QUARTER_MONTH`).

Author extraction: the article page's `.bulletin-header-left` div
contains `<p><strong>Name</strong></p>` + `<p>Affiliation</p>` +
`<h6>Citation: INITIALS. Surname YEAR OIML Bulletin ROMAN(N) ARTID</h6>`.
The citation line is the most reliable structured signal (volume roman,
issue, year, article id).

### Maintained vs one-off

Only the HTML path is maintained — `lib/oiml_fetcher/bulletin_fetcher.rb`
+ the `oiml-fetch bulletin` Thor task. New Bulletin issues keep appearing
only in HTML; this fetcher runs alongside the publication fetcher.

The historical backfill (PDF text layer, GLM-OCR for scans, docx
contents-spine, reconciler) lives under `backfill/` as **one-off**
scripts. They are NOT in `lib/`, NOT in CI, NOT in the cron. See
`backfill/README.md` for the workflow. Once the historical data is
loaded, those scripts can be archived.

## Other-language translations — plain HTML, NOT the API

`https://www.oiml.org/en/publications/other-language-translations/<lang>/<lang>`
**is** server-rendered HTML. Scrape with Nokogiri:

```ruby
doc = Nokogiri::HTML(body)
doc.css("table.colour tr").drop(1).each do |tr|
  tds = tr.css("td")
  next if tds.length < 3
  ref    = tds[0].text.squish              # "R 35-1:2007"
  pdf    = tds[0].at_css("a")["href"]      # ".../r035-1-de-07.pdf"
  title  = tds[1].text.squish
  origin = tds[2].text.squish              # "PTB" / "DIN" / ...
end
```

Each row becomes its own translation instance YAML (separate file), not a
relation on the English item. `origin` (PTB, DIN, ISIRI, …) names the body
that produced the translation → goes into `contributor.role.type:
translator`.

10 languages, one page each. The Polish URL redirects once (307) —
`fetch_with_redirects` follows up to 5 hops.

## Repo layout

```
data/                     # work + instance YAMLs, e.g.
  r35_2007.yaml           #   work
  r35_2007_eng.yaml       #   EN instance
  r35_2007_fra.yaml       #   FR instance
  r35-1-2007_deu.yaml     #   German translation of part 1
  v1_2022.yaml            #   bilingual single-PDF (no split)
Gemfile                   # psych pin + relaton + pubid + thor + nokogiri + rspec
crawler.rb                # thin entry point → OimlFetcher::Indexer.build
check_data.rb             # round-trip validator, exit 1 on mismatch
exe/oiml-fetch            # binstub ($LOAD_PATH + require "oiml_fetcher")
bin/extract_portfolio.py  # pypdf helper for PDF Portfolio attachments
lib/oiml_fetcher.rb       # module + constants + autoload entries (11 modules)
lib/oiml_fetcher/
  docid.rb                # OimlFetcher::Docid value object (3 input grammars)
  source.rb               # OimlFetcher::Source (.url, .oiml, .local)
  http.rb                 # OimlFetcher::Http seam (NetHttp + Fake adapters)
  yaml_store.rb           # OimlFetcher::YamlStore (write, read, patch, exist?)
  filename_parser.rb      # OimlFetcher::FilenameParser (PDF filename → Docid)
  scrape.rb               # Thor subclass (fetch + index tasks)
  publication_fetcher.rb  # JSON API → work + instances
  bulletin_fetcher.rb     # Bulletin HTML editions → bulletin/volume/issue/article
  translation_fetcher.rb  # HTML table scrape → translation instances
  portfolio_fetcher.rb    # downloads source PDFs + extracts portfolios
  parts_builder.rb        # PDF portfolio parts → part/amendment/annex/errata YAMLs
  caco3_fetcher.rb        # enriches Recommendations from caco3consulting.com
  indexer.rb              # OimlFetcher::Indexer.build (clean-rebuild v1 + v2)
spec/oiml_fetcher/        # rspec specs (71 examples, all passing)
TODO.refactor/            # architecture review plans (6 candidates)
pdfs/                     # gitignored PDF cache
index-v1.yaml             # generated, committed (flat string docid index)
index-v2.yaml             # generated, committed (structured pubid index)
index-v1.zip              # committed zip of index-v1.yaml (maintained by CI)
index-v2.zip              # committed zip of index-v2.yaml (maintained by CI)
README.adoc
.github/workflows/        # reuse relaton/support workflows
```

## Architecture

All modules use Ruby `autoload` (defined in `lib/oiml_fetcher.rb`). No
`require_relative` anywhere in `lib/`. The binstub adds `lib/` to
`$LOAD_PATH` and calls `require "oiml_fetcher"`.

Dependency injection: fetchers accept `yaml_store:` and `http_backend:`
parameters. Tests install `OimlFetcher::Http::Fake` with fixture tables;
production uses `OimlFetcher::Http::NetHttp` (the default).

`OimlFetcher::YamlStore` owns all YAML I/O — encoding (UTF-8), location
resolution, idempotency, and Relaton::Bib::Item serialization. No
`File.write` exists outside `YamlStore`.

`OimlFetcher::Docid` is the single value object for OIML document
identifiers across all three input grammars (short_title, translation_ref,
PDF filename). All fetchers use it for id/docid/filename derivation.

`OimlFetcher::Source` produces correctly-typed source hashes (`.url`,
`.oiml`, `.local`) — prevents the "local path tagged as website" bug.

## Commands

```bash
bundle install
bundle exec oiml-fetch                    # fetch all 7 types × {1,5,6} × {en,fr}
bundle exec oiml-fetch --translations     # also fetch 10 translation pages
bundle exec oiml-fetch --pdfs             # download PDFs + extract portfolios + build parts
bundle exec oiml-fetch --caco3            # enrich Recommendations from caco3consulting.com
bundle exec oiml-fetch bulletin           # fetch Bulletin HTML editions (2025-02 → present)
bundle exec oiml-fetch --type=recommendations --status=1   # narrow scope
bundle exec rspec spec/                   # run 71 specs
bundle exec ruby crawler.rb               # rebuild index-v1.yaml
bundle exec ruby check_data.rb            # round-trip validate
```

## Crawler + check_data contracts

`crawler.rb` delegates to `OimlFetcher::Indexer.build`, which indexes every
`data/*.yaml` by its primary docid into two indexes via `Relaton::Index`:
`index-v1.yaml` (flat string docid → file) and `index-v2.yaml` (structured
pubid identifier → file, with `pubid_class: Pubid::Oiml::Identifier`; each
primary docid is parsed by pubid v2's OIML support). No type-specific logic —
works for works, instances, and translations uniformly. It calls
`idx.remove_all` first so both indexes are **rebuilt from scratch** each run:
`Relaton::Index.find_or_create` loads the existing index and `add_or_update`
never prunes, so without the reset, entries for renamed/deleted data files
would linger as orphans. v1 output is sorted by filename (`Dir[...].sort`); v2
is sorted by pubid id number (relaton-index). A docid pubid can't parse is
warned and skipped from v2 only — it never drops out of v1.

`crawler.rb` writes only the YAML; the `relaton/support` crawler workflow zips
each `index*.yaml` into `index*.zip` and commits both (its `commit-indexes`
input defaults to `true`). The zips are committed and consumed by relaton-db at
runtime; the workflow re-zips only when a YAML changes and otherwise restores
the committed zip, so `index-v1.zip` / `index-v2.zip` must stay in the repo.
Each zip holds exactly its `index-vN.yaml` by basename — to regenerate by hand:
`zip index-v1.zip index-v1.yaml` (or rubyzip, since `zip` may be absent).

`check_data.rb` round-trips every YAML through `Relaton::Bib::Item.from_yaml`
→ `to_yaml` and diffs against the source. Exit 1 on any byte mismatch.

## Gemfile

```ruby
gem "psych", "~> 5.2.6"   # 5.3.0 breaks YAML round-trip

# relaton is a single consolidated gem (the former relaton-bib / relaton-core /
# relaton-index / relaton-logger sub-gems were merged into it).
gem "relaton", git: "https://github.com/relaton/relaton.git", branch: "main"
gem "pubid", git: "https://github.com/metanorma/pubid.git",
             branch: "rt-new-lutaml-model"   # pubid v2 (OIML support)

gem "thor", "~> 1.3"
gem "nokogiri"
gem "net-http-persistent"
gem "activesupport", require: false   # String#squish
```

HTTPS git sources so the GH Action can clone anonymously.

## Strict fetches — no fallbacks

`STATUS_NAMES`, `LANG_CODE`, and `DOCID_LANG_CODE` use bare `.fetch(key)`
(no default). A missing key means the map is incomplete — raising is the
correct behavior; silent defaults produce malformed data. When a new
language or status appears upstream, the scrape fails loudly and the map
gets updated.

Discovered this way: `idStatus=2` (FR-only in-force marker) was missing
from `STATUS_NAMES` and surfaced as a KeyError on the first scrape that
hit it.

## Conventions worth preserving

- **Always read/write YAML with `encoding: "UTF-8"`** — OIML titles contain
  accentuated French (é, è, …).
- **Pin `psych ~> 5.2.6`** — 5.3.0 silently breaks the round-trip.
- **GitHub Actions reuse `relaton/support` workflows** — do not write
  custom ones.
- **Never commit to `main`, never push tags.** All changes go through a PR.
- **The crawler runs daily via `relaton/support` cron** (14:00 UTC). Local
  scrapes must produce byte-identical output when nothing upstream changed.

## Reference files in sibling repos

- `relaton-data-iho/crawler.rb` — canonical crawler pattern (now adapted).
- `relaton-data-iho/check_data.rb` — round-trip validator inspiration.
- `relaton/lib/relaton/bib/model/relation.rb` — full relation type
  vocabulary (`hasInstance`, `instanceOf`, `translatedFrom`,
  `hasTranslation`, etc.).
- `relaton/lib/relaton/bib/model/contributor.rb` — full contributor
  role type vocabulary (`author`, `publisher`, `translator`, etc.).
