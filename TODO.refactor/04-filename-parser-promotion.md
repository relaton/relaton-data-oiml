# 04 — Promote `FilenameParser` to top-level

## Problem

`FilenameParser` is a private inner class of `PartsBuilder`. To exercise it
you must instantiate `PartsBuilder` and reach into private state. It returns
a bespoke `OpenStruct` instead of the `Docid` value object (Candidate 1).

## Solution

`OimlFetcher::FilenameParser` as a top-level module:

```ruby
class FilenameParser
  def self.parse(filename)  # "R035-1-e07.pdf" → Docid
end
```

Returns an `OimlFetcher::Docid` directly (Candidate 1). The grammar stays
where it is — only the container changes.

`PartsBuilder` becomes a thin orchestrator:
- Walk `pdfs/*/parts_*/*.pdf`
- For each path, call `FilenameParser.parse`
- Route by `docid.suffix_type` to the right builder
- Patch the parent series YAML via `YamlStore`

## Files

- `lib/oiml_fetcher/filename_parser.rb` (new — moved from PartsBuilder inner class)
- `spec/oiml_fetcher/filename_parser_spec.rb` (new)
- Refactor `lib/oiml_fetcher/parts_builder.rb` — drop the inner class,
  drop the bespoke OpenStruct, use `FilenameParser.parse`
- Update `lib/oiml_fetcher.rb` — `autoload :FilenameParser, "oiml_fetcher/filename_parser"`

## Spec coverage

- All real-world filename shapes parse to the correct `Docid`:
  - `R100-1-e13.pdf` → parts=[1], year=2013, lang=eng
  - `R102-Ann-B-C-e95.pdf` → suffix=annex, annex_letter=B-C
  - `R035-1_amend-e14.pdf` → suffix=amendment, year=2014
  - `R126-e12-errata-e15.pdf` → suffix=errata, year=2015, original_year=2012
  - `R107-1-e07-reconfirmed-2024.pdf` → reconfirmed_year=2024
  - `R046-1-2-e12.pdf` → parts=[1, 2]
- Non-`.pdf` attachments are rejected (return nil or raise — pick one)
- Garbage input returns nil (parse failure)

## Constraints

- Returns a `Docid`, not a bespoke struct.
- No `OpenStruct`.
- No `require_relative`.
