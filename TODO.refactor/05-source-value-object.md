# 05 — `OimlFetcher::Source` value object

## Problem

`PartsBuilder#build_instance` emits:

```yaml
source:
- type: website           # ← lie
  content: pdfs/r35_2007/parts_eng/r035-1-e07.pdf
```

The path is local; the type says "website". The lie is invisible at the
call site because the hash literal hides it.

The `full_url(path)` helper (which prepends `BASE_URL` to relative paths)
also lives in two places — `PublicationFetcher` and `TranslationFetcher` —
duplicated.

## Solution

`OimlFetcher::Source`:

```ruby
class Source
  def self.url(url)        # → { "type" => "website", "content" => url }
  def self.oiml(path)      # prepends BASE_URL if relative → url() above
  def self.local(path)     # → { "type" => "file", "content" => path }
end
```

Each constructor returns a relaton-compatible source hash with the correct
type. Callers cannot accidentally produce a local path tagged as `website`.

## Files

- `lib/oiml_fetcher/source.rb` (new)
- `spec/oiml_fetcher/source_spec.rb` (new)
- Refactor all callers:
  - `PublicationFetcher#build_instance_hash` — `Source.oiml(url)`
  - `TranslationFetcher#write_translation` — `Source.oiml(pdf_url)`
  - `PartsBuilder#build_instance` — `Source.local("pdfs/#{rel_path}")`
- Delete `full_url` helpers from both fetchers
- Update `lib/oiml_fetcher.rb` — `autoload :Source, "oiml_fetcher/source"`

## Spec coverage

- `Source.url("https://...")` returns website-typed hash
- `Source.oiml("en/files/pdf_r/r035.pdf")` prepends `BASE_URL`
- `Source.oiml("https://...")` leaves absolute URL alone
- `Source.local("pdfs/...")` returns file-typed hash
- All three return hashes with `content` keys

## Constraints

- Pure value object — no I/O.
- No `require_relative`.
