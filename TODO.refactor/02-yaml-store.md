# 02 — `OimlFetcher::YamlStore`

## Problem

Five callsites hand-roll YAML I/O with the same load-bearing convention
(`encoding: "UTF-8"`) and slightly different idempotency policies:

| Callsite                        | Behaviour                                       |
|---------------------------------|-------------------------------------------------|
| PublicationFetcher#write_yaml   | overwrites, no skip                             |
| TranslationFetcher (inline)     | overwrites, no skip                             |
| PartsBuilder#write_yaml         | skips if file exists                            |
| PartsBuilder#patch_one_series   | read-modify-write with `YAML.safe_load` + dump  |
| PortfolioFetcher#process_yaml   | reads, walks `source` keys                      |

UTF-8 enforcement lives in each file by repetition. Idempotency rules
diverge silently.

## Solution

`OimlFetcher::YamlStore`:

```ruby
class YamlStore
  def initialize(dir)                      # @dir = absolute path
  def write(name, hash, overwrite: true)   # writes data/<name>.yaml, UTF-8
  def read(name)                           # → hash (parsed via Relaton)
  def patch(name, overwrite: true) { |hash| new_hash }
  def exist?(name)
  def each_yaml(&block)                    # iterates all YAMLs in dir
end
```

Encoding, location resolution, idempotency policy, and round-trip
serialization (via `Relaton::Bib::Item`) all live behind the seam.

## Files

- `lib/oiml_fetcher/yaml_store.rb` (new)
- `spec/oiml_fetcher/yaml_store_spec.rb` (new)
- Refactor all 5 callsites to use a shared `YamlStore` instance
- Update `lib/oiml_fetcher.rb` — `autoload :YamlStore, "oiml_fetcher/yaml_store"`

## Spec coverage

- write creates a UTF-8 file with the expected content
- write with `overwrite: false` skips when file exists (no error)
- write with `overwrite: true` overwrites
- read round-trips a written hash
- patch reads → yields → writes
- exist? returns true/false correctly
- each_yaml yields every `.yaml` file
- UTF-8 preserved (accented French titles round-trip cleanly)

## Constraints

- No `File.write` outside this module.
- All paths resolved relative to `@dir`, never the CWD.
- No `require_relative`.
