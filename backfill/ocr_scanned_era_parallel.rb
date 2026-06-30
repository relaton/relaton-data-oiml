# frozen_string_literal: true

# One-off: GLM-OCR every Bulletin PDF (scanned AND born-digital) in
# PARALLEL. Spawns N worker processes that each pull from the same queue
# of pending issues. Each worker writes via tmp+rename for atomicity.
#
# We use GLM OCR for ALL PDFs because poppler's `pdftotext` does not
# preserve multi-column layouts — the Bulletin's bilingual parallel
# columns get interleaved, producing garbage.
#
# Run:
#   bundle exec ruby backfill/ocr_scanned_era_parallel.rb [workers]

$LOAD_PATH.unshift(File.expand_path("../lib", __dir__))
require "oiml_fetcher"
$LOAD_PATH.unshift(File.expand_path("../backfill", __dir__))
require "glm_ocr"
require "fileutils"
require "open3"
require "tmpdir"

module BulletinBackfill
  class OcrScannedEraParallel
    # No year cutoff — process ALL pending issues regardless of era.
    def initialize(bulletin_data_root:, workers: 3, year_filter: nil)
      @root = bulletin_data_root
      @workers = workers
      @year_filter = year_filter
    end

    def run
      dirs = pending_dirs
      if dirs.empty?
        puts "Nothing pending — all issues have ocr.md."
        return
      end
      puts "Pending: #{dirs.size} issues across #{@workers} workers"

      batches = dirs.each_slice((dirs.size / @workers.to_f).ceil).to_a
      pids = batches.map do |batch|
        fork do
          $0 = "ocr-worker-#{Process.pid}"
          worker_loop(batch)
        end
      end
      pids.each { |pid| Process.wait(pid) }
    end

    private

    def pending_dirs
      dirs = Dir[File.join(@root, "[0-9][0-9][0-9][0-9]", "[0-9][0-9]")]
      dirs = dirs.select { |d| year_of(d) < 2000 } if @year_filter == :scanned
      dirs = dirs.select { |d| year_of(d) == @year_filter.to_i } if @year_filter.is_a?(Integer)
      dirs.reject { |d| File.exist?(File.join(d, "ocr.md")) }
          .reject { |d| Dir[File.join(d, "*.pdf")].empty? }
          .sort
    end

    def year_of(dir)
      dir.match(%r{/(\d{4})/\d{2}\z}) && Regexp.last_match(1).to_i
    end

    def worker_loop(dirs)
      ocr = BulletinBackfill::GlmOcr.new
      dirs.each do |dir|
        process_issue(dir, ocr)
      rescue StandardError => e
        warn "[#{Process.pid}] failed #{dir}: #{e.message}"
      end
    end

    def process_issue(dir, ocr)
      pdf = Dir[File.join(dir, "*.pdf")].first
      return unless pdf

      md_path = File.join(dir, "ocr.md")
      return if File.exist?(md_path)

      pages = pdf_page_count(pdf)
      return unless pages && pages.positive?

      # GLM-OCR limits: PDF ≤ 50MB, ≤ 100 pages. Chunk within that.
      pages = [pages, 100].min
      t0 = Time.now
      md = ocr.ocr_pdf(pdf, num_pages: pages)
      tmp = "#{md_path}.tmp.#{Process.pid}"
      File.write(tmp, md, encoding: "UTF-8")
      File.rename(tmp, md_path)
      warn "[#{Process.pid}] OCR #{File.basename(File.dirname(pdf))}/#{File.basename(pdf)}: #{pages}p, #{(Time.now - t0).round(1)}s"
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
  workers = (ARGV[0] || 3).to_i
  # Stop any existing OCR processes first to avoid API contention.
  existing = `pgrep -f "ruby backfill/ocr_"`.split
  unless existing.empty?
    warn "Stopping existing OCR processes: #{existing.inspect}"
    existing.each { |pid| Process.kill("TERM", pid.to_i) rescue nil }
    sleep 3
  end
  BulletinBackfill::OcrScannedEraParallel.new(bulletin_data_root: root, workers: workers).run
end

