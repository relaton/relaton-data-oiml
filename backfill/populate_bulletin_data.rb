# frozen_string_literal: true

# One-off: populate ~/src/oimlsmart/bulletin-data/ with every OIML Bulletin
# PDF (downloaded) and OCR'd content (born-digital via pdftotext, scanned
# via GLM OCR). NOT maintained.
#
# Output layout:
#   <bulletin-data>/
#     README.adoc
#     <year>/<issue>/<filename>.pdf      # original PDF
#     <year>/<issue>/ocr.md              # OCR'd text (pdftotext or GLM)
#     <year>/<issue>/ocr.json            # GLM API response (scanned era only)
#
# Each PDF is filed by (year, quarterly-issue). Born-digital PDFs (2000+)
# are processed inline; scanned PDFs (pre-2000) are queued for GLM OCR via
# a separate script (TODO 05).
#
# Run:
#   bundle exec ruby backfill/populate_bulletin_data.rb

$LOAD_PATH.unshift(File.expand_path("../lib", __dir__))
require "oiml_fetcher"
require "yaml"
require "fileutils"
require "open3"
require "open-uri"

module BulletinBackfill
  class PopulateBulletinData
    BORN_DIGITAL_YEAR_CUTOFF = 2000
    PAGES_PER_GLAM_CHUNK = 30
    # Skip the 2024-01 / 2024-04 PDFs already inlined by process_pdf_gap.rb.
    SKIP_PDFS = %w[
      oiml_bulletin_jan_2024.pdf oiml_bulletin_april_2024.pdf
    ].freeze

    attr_reader :stats

    def initialize(root:, pdf_index:)
      @root = root
      @pdf_index = pdf_index
      @stats = Hash.new(0)
    end

    def run
      FileUtils.mkdir_p(@root)
      write_readme
      PDFIndex.each(@pdf_index) do |entry|
        next if SKIP_PDFS.include?(File.basename(entry["url"]))

        file_entry(entry)
      end
      self
    end

    private

    def file_entry(entry)
      year, issue = entry["year"], entry["issue"]
      unless year && issue
        warn "  skip (no slug): #{entry['url']}"
        @stats[:skipped_no_slug] += 1
        return
      end

      issue_dir = File.join(@root, year.to_s, format("%02d", issue.to_i))
      FileUtils.mkdir_p(issue_dir)
      pdf_path = File.join(issue_dir, File.basename(entry["url"]))
      download(entry["url"], pdf_path)

      md_path = File.join(issue_dir, "ocr.md")
      if File.exist?(md_path)
        @stats[:already_done] += 1
      elsif year >= BORN_DIGITAL_YEAR_CUTOFF
        extract_with_pdftotext(pdf_path, md_path)
        @stats[:born_digital] += 1
      else
        # Scanned-era PDF — leave for TODO 05 (separate script).
        @stats[:scanned_pending] += 1
      end
    end

    def download(url, dest)
      return dest if File.exist?(dest)

      URI.open(url, "User-Agent" => "relaton-data-oiml") do |r|
        File.binwrite(dest, r.read)
      end
      dest
    rescue OpenURI::HTTPError, Timeout::Error => e
      warn "  download failed #{url}: #{e.message}"
      @stats[:download_errors] += 1
      nil
    end

    def extract_with_pdftotext(pdf_path, md_path)
      # -layout preserves the visual layout (important for TOC parsing).
      text, status = Open3.capture2("pdftotext", "-layout", pdf_path, "-")
      unless status.success?
        warn "  pdftotext failed for #{pdf_path}"
        @stats[:pdftotext_errors] += 1
        return
      end

      # Wrap as minimal markdown: title prefix + body.
      year_issue = pdf_path.match(%r{/(\d{4})/(\d{2})/}) && "#{$1}-#{$2}"
      front = "---\nsource: #{File.basename(pdf_path)}\nslug: #{year_issue}\nmethod: pdftotext\n---\n\n# OIML Bulletin #{year_issue}\n\n"
      File.write(md_path, front + text, encoding: "UTF-8")
    end

    def write_readme
      path = File.join(@root, "README.adoc")
      return if File.exist?(path)

      File.write(path, <<~ADOC)
        = OIML Bulletin source data

        Mirror of every OIML Bulletin PDF published on https://www.oiml.org,
        with text extractions alongside each issue.

        == Layout

        ```
        <year>/<issue>/          # e.g. 2024/01
          <filename>.pdf         # original PDF
          ocr.md                 # text extraction (pdftotext for born-digital, GLM-OCR for scans)
          ocr.json               # GLM-OCR raw response (scanned-era only)
        ```

        Year is the calendar year. Issue is the quarterly issue number
        within the year (01 = Jan/Q1, 02 = Apr/Q2, 03 = Jul/Q3, 04 = Oct/Q4).

        == Extraction methods

        * *Born-digital* PDFs (year >= 2000): `pdftotext -layout` (poppler).
          Fast, deterministic, no API cost.
        * *Scanned* PDFs (year < 2000): GLM OCR via the z.ai layout_parsing
          API. Cached per 30-page chunk in `backfill/cache/`.

        == Source

        All PDFs are downloaded from oiml.org public URLs. The bulletin
        landing page is
        https://www.oiml.org/en/publications/oiml-bulletin/online-bulletin.

        == Regeneration

        This tree is produced by `backfill/populate_bulletin_data.rb` in the
        `relaton-data-oiml` repository. Re-running is idempotent — existing
        PDFs and ocr.md files are left in place.
      ADOC
    end

    # Wrapper around pdf_index.yaml entries.
    class PDFIndex
      def self.each(path)
        YAML.load_file(path).each { |e| yield e }
      end
    end
  end
end

if $PROGRAM_NAME == __FILE__
  root = File.expand_path("~/src/oimlsmart/bulletin-data")
  pdf_index = File.expand_path("cache/pdf_index.yaml", __dir__)
  abort "missing #{pdf_index} (run backfill/pdf_index.rb first)" unless File.exist?(pdf_index)

  r = BulletinBackfill::PopulateBulletinData.new(root: root, pdf_index: pdf_index).run
  puts "bulletin-data populated:"
  puts "  born-digital extracted: #{r.stats[:born_digital]}"
  puts "  scanned pending OCR: #{r.stats[:scanned_pending]}"
  puts "  already done: #{r.stats[:already_done]}"
  puts "  skipped (no slug): #{r.stats[:skipped_no_slug]}"
  puts "  download errors: #{r.stats[:download_errors]}"
end
