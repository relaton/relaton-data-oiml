# frozen_string_literal: true

# One-off: split oversized Bulletin PDFs (>50MB) into chunks under 50MB and
# GLM-OCR each chunk separately. Reassembles the markdown into a single
# ocr.md in the year/issue folder.
#
# Run:
#   bundle exec ruby backfill/ocr_oversize.rb

$LOAD_PATH.unshift(File.expand_path("../lib", __dir__))
require "oiml_fetcher"
$LOAD_PATH.unshift(File.expand_path("../backfill", __dir__))
require "glm_ocr"
require "fileutils"
require "open3"
require "tmpdir"

module BulletinBackfill
  class OcrOversize
    # Each chunk should fit in GLM-OCR's 50MB limit AND ≤100 pages.
    # 50MB at ~3MB/page (high-res scanned) ≈ 15 pages; we use 12 to be safe.
    CHUNK_PAGES = 12
    SIZE_LIMIT_BYTES = 50 * 1024 * 1024

    def initialize(bulletin_data_root:)
      @root = bulletin_data_root
      @skip_dir = File.join(@root, "skipped_oversize_pdfs")
      @ocr = BulletinBackfill::GlmOcr.new
    end

    def run
      Dir[File.join(@skip_dir, "*.pdf")].each do |pdf|
        process_oversize(pdf)
      rescue StandardError => e
        warn "  failed #{pdf}: #{e.message}"
      end
    end

    private

    def process_oversize(pdf_path)
      basename = File.basename(pdf_path, ".pdf")
      puts "=== #{basename} ==="
      pages = pdf_page_count(pdf_path)
      size = File.size(pdf_path)
      puts "  #{size / 1024 / 1024}MB, #{pages} pages"
      return unless pages && pages.positive?

      # Split into chunks of CHUNK_PAGES each, then OCR each chunk.
      # GLM-OCR's 30-page-per-request limit applies on top, so within
      # each chunk we further slice into 30-page windows (handled by ocr_pdf).
      Dir.mktmpdir("ocr-oversize-") do |tmp|
        chunks = split_into_chunks(pdf_path, pages, tmp)
        return if chunks.empty?

        markdown = chunks.map do |chunk|
          chunk_md = @ocr.ocr_pdf(chunk[:path], num_pages: chunk[:pages])
          FileUtils.rm_f(chunk[:path])
          chunk_md
        end.join("\n\n")

        # Determine target directory based on the issue this PDF belongs to.
        target_dir = target_issue_dir(basename)
        FileUtils.mkdir_p(target_dir)
        # Remove the empty placeholder ocr.md (if any) before writing real content.
        placeholder = File.join(target_dir, "ocr.md")
        File.delete(placeholder) if File.exist?(placeholder) && File.size(placeholder) < 1000
        File.write(placeholder, markdown, encoding: "UTF-8")
        puts "  wrote #{placeholder} (#{markdown.size} chars)"
      end
    end

    # Split into chunks of CHUNK_PAGES pages each. Returns [{path:, pages:}].
    def split_into_chunks(pdf_path, total_pages, tmp_dir)
      # Burst to single pages, then group into chunks via pdfunite.
      page_pattern = File.join(tmp_dir, "p_%05d.pdf")
      _, status = Open3.capture2("pdfseparate", pdf_path, page_pattern)
      return [] unless status.success?

      chunks = []
      (1..total_pages).step(CHUNK_PAGES).each do |start_page|
        end_page = [start_page + CHUNK_PAGES - 1, total_pages].min
        chunk_pages = (start_page..end_page).map { |n| format("#{tmp_dir}/p_%05d.pdf", n) }
                                          .select { |p| File.exist?(p) }
        next if chunk_pages.empty?

        chunk_path = File.join(tmp_dir, "chunk_#{start_page}_#{end_page}.pdf")
        _, chunk_status = Open3.capture2("pdfunite", *chunk_pages, chunk_path)
        if chunk_status.success? && File.size(chunk_path) < SIZE_LIMIT_BYTES
          chunks << { path: chunk_path, pages: chunk_pages.size }
        elsif chunk_status.success?
          # Chunk too big — further split in half.
          mid = (chunk_pages.size / 2.0).ceil
          [[chunk_pages[0...mid], 0], [chunk_pages[mid..], 1]].each do |half, idx|
            next if half.empty?

            half_path = File.join(tmp_dir, "half_#{start_page}_#{idx}.pdf")
            _, half_status = Open3.capture2("pdfunite", *half, half_path)
            chunks << { path: half_path, pages: half.size } if half_status.success?
          end
          FileUtils.rm_f(chunk_path)
        end
      end
      chunks
    end

    def pdf_page_count(pdf)
      out, status = Open3.capture2("pdfinfo", pdf)
      return nil unless status.success?

      m = out.match(/^Pages:\s+(\d+)/)
      m && m[1].to_i
    end

    # Map a basename like "oiml_bulletin_april_2018" to "2018/02".
    def target_issue_dir(basename)
      m = basename.match(/(jan(?:uary)?|apr(?:il)?|jul(?:y)?|oct(?:ober)?)[-_]?(\d{4})/i)
      return File.join(@root, "unknown") unless m

      year = m[2].to_i
      issue = MONTH_MAP.fetch(m[1].downcase)
      File.join(@root, year.to_s, format("%02d", issue))
    end

    MONTH_MAP = {
      "jan" => 1, "january" => 1,
      "apr" => 2, "april" => 2,
      "jul" => 3, "july" => 3,
      "oct" => 4, "october" => 4,
    }.freeze
  end
end

if $PROGRAM_NAME == __FILE__
  root = File.expand_path("~/src/oimlsmart/bulletin-data")
  BulletinBackfill::OcrOversize.new(bulletin_data_root: root).run
end
