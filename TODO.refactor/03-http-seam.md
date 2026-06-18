# 03 — `OimlFetcher::Http` seam

## Problem

Three HTTP entry points, none testable offline:

| Fetcher              | Today                                                  |
|----------------------|--------------------------------------------------------|
| PublicationFetcher   | `Net::HTTP.start` + manual GET                         |
| TranslationFetcher   | `Net::HTTP.start` + manual redirect loop               |
| PortfolioFetcher     | `URI.open` (open-uri)                                  |

No common place for redirects, timeouts, politeness, retries, or caching.
Each fetcher hardcodes its own dial-the-network code.

## Solution

A single seam at `OimlFetcher::Http` with swappable backend:

```ruby
module Http
  class << self
    attr_accessor :backend  # default: Http::NetHttp.new
  end

  class NetHttp
    def get(url, redirects: 5, read_timeout: 30, open_timeout: 15)  # → body string
  end

  class Fake
    def initialize(table)  # { url => body, ... } or { regex => body }
    def get(url)           # → body, raises KeyError if not in table
  end

  self.backend = NetHttp.new
end
```

Fetchers call `OimlFetcher::Http.backend.get(url)`. Tests install a `Fake`.

Redirect logic, timeouts, error classes concentrate in `NetHttp`. Two
adapters justify the seam (real + fake) — the test surface stops requiring
the network.

## Files

- `lib/oiml_fetcher/http.rb` (new)
- `spec/oiml_fetcher/http_spec.rb` (new)
- Refactor 3 fetchers to call `Http.backend.get(...)`
- Update `lib/oiml_fetcher.rb` — `autoload :Http, "oiml_fetcher/http"`

## Spec coverage

- `Fake` returns the body for a known URL
- `Fake` raises if URL not in the table
- `NetHttp` follows a 301/302/307 redirect (test with a stub server or
  WebMock — pick one and stay consistent)
- `NetHttp` raises on HTTP 4xx/5xx
- `NetHttp` raises on timeout (testable via stub)

## Constraints

- No `Net::HTTP.start` or `URI.open` outside `Http::NetHttp`.
- Backend is swappable via the class-level accessor — no global reassignment
  in fetcher code.
- No `require_relative`.
