# frozen_string_literal: true

# One-off: populate ~/src/oimlsmart/bulletin-data/ with every OIML Bulletin
# PDF (downloaded only). NOT maintained.
#
# Output layout:
#   <bulletin-data>/
#     README.adoc
#     <year>/<issue>/<filename>.pdf      # original PDF
#     <year>/<issue>/ocr.md              # OCR'd text (written by GLM OCR script)
#     <year>/<issue>/ocr.json            # GLM API response
#
# This script ONLY downloads PDFs. OCR is done separately by
# backfill/ocr_scanned_era_parallel.rb (which handles ALL eras — scanned
# and born-digital — using GLM OCR for layout-preserving extraction).
#
# We deliberately do NOT use `pdftotext` for born-digital PDFs because
# poppler does not preserve multi-column layouts — the OIML Bulletin's
# bilingual parallel columns get interleaved, producing garbage text.
#
# Run:
#   bundle exec ruby backfill/populate_bulletin_data.rb

$LOAD_PATH.unshift(File.expand_path("../lib", __dir__))
require "oiml_fetcher"
require "yaml"
require "fileutils"
require "open-uri"

module BulletinBackfill
  class PopulateBulletinData
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
        @stats[:skipped_no_slug] += 1
        return
      end

      issue_dir = File.join(@root, year.to_s, format("%02d", issue.to_i))
      FileUtils.mkdir_p(issue_dir)
      pdf_path = File.join(issue_dir, File.basename(entry["url"]))
      download(entry["url"], pdf_path)
    end

    def download(url, dest)
      return dest if File.exist?(dest)

      URI.open(url, "User-Agent" => "relaton-data-oiml") do |r|
        File.binwrite(dest, r.read)
      end
      dest
      @stats[:downloaded] += 1
    rescue OpenURI::HTTPError, Timeout::Error => e
      warn "  download failed #{url}: #{e.message}"
      @stats[:download_errors] += 1
      nil
    end

    def write_readme
      path = File.join(@root, "README.adoc")
      return if File.exist?(path)

      File.write(path, <<~ADOC)
        = OIML Bulletin source data

        Mirror of every OIML Bulletin PDF published on https://www.oiml.org,
        with GLM-OCR text extractions alongside each issue.

        == Layout

        ```
        <year>/<issue>/          # e.g. 2024/01
          <filename>.pdf         # original PDF
          ocr.md                 # GLM-OCR markdown
          ocr.json               # GLM API response (cache)
        ```

        Year is the calendar year. Issue is the quarterly issue number
        within the year (01 = Jan/Q1, 02 = Apr/Q2, 03 = Jul/Q3, 04 = Oct/Q4).

        == Extraction method

        *GLM OCR* via the z.ai layout_parsing API for ALL PDFs (scanned and
        born-digital alike). Cached per 30-page chunk in `backfill/cache/`.

        We deliberately do NOT use `pdftotext` (poppler): poppler does not
        preserve multi-column layouts. The OIML Bulletin's bilingual
        parallel columns get interleaved on `pdftotext` output, producing
        garbage text that cannot be reliably parsed for Contents / SOMMAIRE.

        == Source

        All PDFs are downloaded from oiml.org public URLs. The bulletin
        landing page is
        https://www.oiml.org/en/publications/oiml-bulletin/online-bulletin.

        == Regeneration

        This tree is produced by:

          bundle exec ruby backfill/populate_bulletin_data.rb       # downloads only
          bundle exec ruby backfill/ocr_scanned_era_parallel.rb 2   # GLM OCR, all eras
      ADOC
    end

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
  puts "bulletin-data populate (downloads only):"
  puts "  downloaded: #{r.stats[:downloaded]}"
  puts "  already present: #{r.stats[:skipped_no_slug]}"
  puts "  download errors: #{r.stats[:download_errors]}"
  puts "Run backfill/ocr_scanned_era_parallel.rb next to fill in ocr.md files."
end

