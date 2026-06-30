# 01 — Fix HTML enumerator to pick up `/online-bulletin-1/` subpath

## Problem

The current `BulletinFetcher#enumerate_html_issues` only scans the
`/oiml-bulletin/YYYY-NN` URL pattern. The 2024-07 and 2024-10 HTML
editions actually live at `/oiml-bulletin/online-bulletin-1/YYYY-NN`,
which the regex misses. Result: 2 HTML-era issues are silently absent
from the dataset.

## Solution

Extend the regex/scanner to accept either prefix:

```ruby
html.scan(%r{/en/publications/oiml-bulletin/(?:online-bulletin-1/)?(\d{4}-\d{2})(?=["'/])})
```

Update the issue URL builder to record which prefix the issue was found
under, and use it when fetching the issue index and article pages.

## Acceptance

- `bundle exec oiml-fetch bulletin` picks up 2024-07 and 2024-10 in
  addition to the current 5 HTML-era issues (total: 7)
- The two new issues produce full volume/issue/article records
- Existing 2025-02 → 2026-02 records remain byte-identical (idempotency)
- New rspec example covering both URL patterns
