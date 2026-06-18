# 01 — `OimlFetcher::Docid` value object

## Problem

Three fetchers each derive the same kind of value (an OIML docid) from three
different input grammars, each with its own private helper pile:

| Fetcher              | Input grammar             | Helper(s)                                            |
|----------------------|---------------------------|------------------------------------------------------|
| PublicationFetcher   | `"R 35:2007(en)"`         | `docid_from`, `id_for`, `filename_for`               |
| TranslationFetcher   | `"R 35-1:2007"`           | `id_for`, `filename_for`, `strip_locale_suffix`      |
| PartsBuilder         | `"R035-1-e07.pdf"`        | `work_docid`, `base_docid_with_parts`, `series_docid`, `series_year`, `amends_target_docid`, `id_from_docid`, `work_filename`, `instance_filename` |

Grammar drift between them is silent. The deletion test passes — delete any
one helper pile and the complexity reappears verbatim in the others plus one
new place.

## Solution

A value object `OimlFetcher::Docid` with:

- Three constructor methods (one per input grammar):
  - `.from_short_title("R 35:2007(en)")`
  - `.from_translation_ref("R 35-1:2007")`
  - `.from_pdf_filename("R035-1-e07.pdf")` (delegates to `FilenameParser`)
- Immutable accessors: `prefix`, `number`, `parts`, `year`, `original_year`,
  `lang` (ISO 639-3, may be nil), `suffix_type` (nil / `:amendment` /
  `:annex` / `:annexes` / `:errata`), `annex_letter`, `reconfirmed_year`
- Derived forms:
  - `to_s` → `"OIML R 35:2007"`
  - `id` → `"R35-2007"`
  - `filename_stem` → `"r35_2007"`
  - `for_lang(lang_code)` → returns a new `Docid` with the given language
  - `for_suffix(suffix_type, year: nil, annex_letter: nil)` → returns a new
    `Docid` representing an amendment / annex / errata of this one
  - `relation_target` → bibitem docid string

## Files

- `lib/oiml_fetcher/docid.rb` (new)
- `spec/oiml_fetcher/docid_spec.rb` (new)
- Update `lib/oiml_fetcher.rb` — add `autoload :Docid, "oiml_fetcher/docid"`

## Spec coverage

- Each constructor: parses prefix, number, parts, year, lang, suffix_type,
  annex_letter correctly across all real-world filename shapes
- Round-trip: `Docid.from_short_title(x).to_s == cleaned_x`
- Derived forms: `id`, `filename_stem`, `for_lang`, `relation_target`
- Edge cases: combined parts (`R 46-1-2`), amendments (`_amend-e14`),
  annexes (`Annex-B-C`), errata, reconfirmed, original-year-embedded
  (`R126-e12-errata-e15`)

## Constraints

- Pure value object — no I/O, no globals, no mutation.
- Immutable: setters not defined.
- No `require_relative` — autoload only.
