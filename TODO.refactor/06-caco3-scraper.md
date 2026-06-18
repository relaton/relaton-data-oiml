# 06 — Caco3Consulting scraper for enriched Recommendation metadata

## Problem

The oiml.org JSON API provides basic metadata (title, edition year, TC,
status, PDF URL). The demo site at `oiml.caco3consulting.com` provides
significantly richer data for Recommendations (R series only):

- **Scope** (free text)
- **Quantity** (e.g., Mass, Length, Volume — linked to SI digital framework)
- **Measuring Instrument** (e.g., "Automatic weighing instrument")
- **OIML Focus Area** (Trade / Health / Safety / Environment)
- **3Ps Sustainability Framework** (Prosperity / People / Planet)
- **DOI** (e.g., `10.63493/r150.2020.en`)
- **Part titles** (e.g., "Part 1: Metrological and technical requirements")
- **All editions** (superseded + current + withdrawn)

## URL structure

```
/recommendations/?status=all           → list of all R numbers
/recommendation/{number}/              → all editions of one R
/recommendation/{number}/{year}/       → edition-level metadata
/recommendation/{number}/{year}/{part}/→ part-level metadata
```

All pages are server-rendered HTML (Django/Bootstrap). Nokogiri scrape.

## Solution

`OimlFetcher::Caco3Fetcher` — enriches existing `data/r{N}_{year}*.yaml`
files by patching in caco3 metadata under `ext`. Does NOT create new files
(except part-level titles, which update existing PartsBuilder output).

Non-standard fields go in `ext`:

```yaml
ext:
  doctype: recommendation
  flavor: oiml
  scope: "This International Recommendation specifies..."
  quantity: Mass
  measuring_instrument: Automatic weighing instrument
  focus_area: Trade
  sustainability_framework: Prosperity
  doi: 10.63493/r150.2020.en
```

For parts, the title gets updated from the caco3 "Part N: ..." text
(replacing the placeholder "Part N").

## Files

- `lib/oiml_fetcher/caco3_fetcher.rb` (new)
- `spec/oiml_fetcher/caco3_fetcher_spec.rb` (new)
- Update `lib/oiml_fetcher.rb` — `autoload :Caco3Fetcher`
- Update `lib/oiml_fetcher/scrape.rb` — `--caco3` flag

## Constraints

- Uses `OimlFetcher::Http` for all fetching (testable with Fake).
- Uses `OimlFetcher::YamlStore` for patching existing YAMLs.
- Only enriches Recommendations (R prefix). Other types untouched.
- Idempotent: re-running doesn't duplicate `ext` fields.
