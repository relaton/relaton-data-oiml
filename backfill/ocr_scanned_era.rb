# frozen_string_literal: true

# One-off: GLM-OCR the scanned-era Bulletin PDFs (pre-2000) and write
# markdown alongside each PDF in ~/src/oimlsmart/bulletin-data/. NOT
# maintained. NOT in lib/, CI, or cron.
#
# Run AFTER populate_bulletin_data.rb has downloaded the scanned PDFs.
# Re-running resumes from cache (per-chunk JSON cached in backfill/cache/).
#
# Run:
#   bundle exec ruby backfill/ocr_scanned_era.rb [--year 1973]

$LOAD_PATH.unshift(File.expand_path("../lib", __dir__))
require "oiml_fetcher"
$LOAD_PATH.unshift(File.expand_path("../backfill", __dir__))
require "glm_ocr"
require "fileutils"
require "open3"

module BulletinBackfill
  class OcrScannedEra
    BORN_DIGITAL_YEAR_CUTOFF = 2000

    attr_reader :stats

    def initialize(bulletin_data_root:, year_filter: nil)
      @root = bulletin_data_root
      @year_filter = year_filter
      @ocr = BulletinBackfill::GlmOcr.new
      @stats = Hash.new(0)
    end

    def run
      scanned_issue_dirs.each do |dir|
        process_issue(dir)
      rescue StandardError => e
        warn "  OCR failed for #{dir}: #{e.message}"
        @stats[:errors] += 1
      end
      self
    end

    private

    def scanned_issue_dirs
      dirs = Dir[File.join(@root, "[0-9][0-9][0-9][0-9]", "[0-9][0-9]")]
             .select { |d| year_of(d) < BORN_DIGITAL_YEAR_CUTOFF }
      dirs = dirs.select { |d| year_of(d) == @year_filter } if @year_filter
      dirs.sort
    end

    def year_of(dir)
      dir.match(%r{/(\d{4})/\d{2}\z}) && Regexp.last_match(1).to_i
    end

    def process_issue(dir)
      pdf = Dir[File.join(dir, "*.pdf")].first
      unless pdf
        @stats[:no_pdf] += 1
        return
      end
      md_path = File.join(dir, "ocr.md")
      if File.exist?(md_path)
        @stats[:already_done] += 1
        return
      end

      pages = pdf_page_count(pdf)
      return @stats[:zero_pages] += 1 unless pages && pages.positive?

      # GLM-OCR's 100-page-per-PDF limit; chunk within that.
      pages = [pages, 100].min
      t0 = Time.now
      md = @ocr.ocr_pdf(pdf, num_pages: pages)
      File.write(md_path, md, encoding: "UTF-8")
      @stats[:ocr_done] += 1
      warn "  OCR #{File.basename(File.dirname(pdf))}/#{File.basename(pdf)}: #{pages}p, #{(Time.now - t0).round(1)}s, #{md.size} chars"
    end

    def pdf_page_count(pdf)
      out, status = Open3.capture2("pdfinfo", pdf)
      return nil unless status.success?

      m = out.match(/^Pages:\s+(\d+)/)
      m && m[1].to_i
    end
  end
end

if $PROGRAM_NAME == __FILE__
  root = File.expand_path("~/src/oimlsmart/bulletin-data")
  year_filter = ARGV.index("--year") && ARGV[ARGV.index("--year") + 1]&.to_i
  r = BulletinBackfill::OcrScannedEra.new(bulletin_data_root: root, year_filter: year_filter).run
  puts "OCR'd scanned-era issues:"
  puts "  completed: #{r.stats[:ocr_done]}"
  puts "  already done: #{r.stats[:already_done]}"
  puts "  no PDF: #{r.stats[:no_pdf]}"
  puts "  errors: #{r.stats[:errors]}"
end
