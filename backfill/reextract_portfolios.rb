#!/usr/bin/env ruby
# Re-extract PDF Portfolio attachments for all portfolio PDFs in pdfs/.
# One-off: run after pyprf/is uninitialized or after extract_portfolio.py upgrades.

require "open3"
require "fileutils"
require "json"

PDFS_DIR = File.expand_path("../pdfs", __dir__)
HELPER = File.expand_path("../bin/extract_portfolio.py", __dir__)

stats = { portfolios: 0, parts: 0, failed: 0, zero: 0 }
Dir.glob(File.join(PDFS_DIR, "**/*-p-*.pdf")).sort.each do |path|
  parts_dir = File.join(File.dirname(path), "parts_eng")
  FileUtils.mkdir_p(parts_dir)
  out, status = Open3.capture2("python3", HELPER, path, parts_dir)
  if status.success?
    count = JSON.parse(out)["count"].to_i
    stats[:portfolios] += 1
    stats[:parts] += count
    if count.zero?
      stats[:zero] += 1
      warn "  WARN 0 parts: #{File.basename(path)}"
    end
  else
    stats[:failed] += 1
    warn "  FAIL #{File.basename(path)}"
  end
end
puts "Portfolios: #{stats[:portfolios]}  Parts: #{stats[:parts]}  Zero: #{stats[:zero]}  Failed: #{stats[:failed]}"
