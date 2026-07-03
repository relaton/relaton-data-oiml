# frozen_string_literal: true

# One-off: OCR GLM-blocked Bulletin PDFs using Tesseract as fallback.
# NOT maintained. Used for the 5+ issues where GLM's content filter
# blocks every page.
#
# Run:
#   bundle exec ruby backfill/tesseract_fallback.rb

require "fileutils"
require "open3"
require "tmpdir"

module BulletinBackfill
  class TesseractFallback
    BLOCKED_ISSUES = %w[
      2018/03 2018/04 2019/02 2023/01 2023/02
    ].freeze

    attr_reader :stats

    def initialize(bulletin_data_root)
      @root = bulletin_data_root
      @stats = Hash.new(0)
    end

    def run
      BLOCKED_ISSUES.each do |slug|
        dir = File.join(@root, slug)
        pdf = Dir[File.join(dir, "*.pdf")].first
        unless pdf && File.exist?(pdf)
          warn "  skip #{slug}: no PDF"
          next
        end

        ocr_md = File.join(dir, "ocr.md")
        if File.exist?(ocr_md) && File.size(ocr_md) > 10_000
          warn "  skip #{slug}: already has real OCR"
          next
        end

        process_issue(slug, pdf, ocr_md)
      end
    end

    private

    def process_issue(slug, pdf, ocr_md)
      pages = pdf_page_count(pdf)
      return unless pages && pages.positive?

      warn "  Tesseract OCR #{slug} (#{pages}p)..."
      tmp_dir = File.join(Dir.tmpdir, "tess-#{slug.tr('/', '-')}")
      FileUtils.rm_rf(tmp_dir)
      FileUtils.mkdir_p(tmp_dir)

      # Convert PDF to images at 200 DPI (good balance of quality/speed).
      _, status = Open3.capture2("pdftoppm", "-r", "200", "-png", pdf,
                                 File.join(tmp_dir, "page"))
      unless status.success?
        warn "    pdftoppm failed for #{pdf}"
        return
      end

      images = Dir[File.join(tmp_dir, "page-*.png")].sort
      markdown_parts = []
      images.each_with_index do |img, idx|
        page_num = idx + 1
        # Use eng+fra for bilingual issues
        txt_out = File.join(tmp_dir, "page_#{page_num}")
        _, tess_status = Open3.capture2("tesseract", img, txt_out, "-l", "eng+fra", "--psm", "6")
        if tess_status.success? && File.exist?("#{txt_out}.txt")
          text = File.read("#{txt_out}.txt", encoding: "UTF-8").strip
          markdown_parts << "<!-- page #{page_num} -->\n\n#{text}"
        else
          markdown_parts << "<!-- page #{page_num}: OCR failed -->"
        end
      end

      FileUtils.rm_rf(tmp_dir)
      md = "---\nsource: #{File.basename(pdf)}\nslug: #{slug.tr('/', '-')}\nmethod: tesseract\n---\n\n# OIML Bulletin #{slug.tr('/', '-')}\n\n" + markdown_parts.join("\n\n---\n\n")
      File.write(ocr_md, md, encoding: "UTF-8")
      @stats[:done] += 1
      warn "    wrote #{ocr_md} (#{md.size} chars)"
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
  BulletinBackfill::TesseractFallback.new(root).run
end
