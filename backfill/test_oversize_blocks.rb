# frozen_string_literal: true

# Test: OCR page 1 of each blocked PDF individually to find which
# page numbers trigger GLM's content filter.
# Run:
#   bundle exec ruby backfill/test_oversize_blocks.rb

$LOAD_PATH.unshift(File.expand_path("../lib", __dir__))
require "oiml_fetcher"
$LOAD_PATH.unshift(File.expand_path("../backfill", __dir__))
require "glm_ocr"

oversize_dir = File.expand_path("~/src/oimlsmart/bulletin-data/skipped_oversize_pdfs")
Dir["#{oversize_dir}/*.pdf"].sort.each do |pdf|
  basename = File.basename(pdf, ".pdf")
  total_pages = `pdfinfo "#{pdf}" 2>/dev/null | grep Pages | awk '{print $2}'`.to_i
  next if total_pages.zero?

  puts "=== #{basename} (#{total_pages}p) ==="
  ocr = BulletinBackfill::GlmOcr.new
  failed = []
  ok = []

  (1..total_pages).each do |page|
    page_pdf = "/tmp/_p_test/#{basename}_p#{page}.pdf"
    FileUtils.mkdir_p("/tmp/_p_test")
    ok_status = system("pdftk", pdf, "cat", page.to_s, "output", page_pdf, out: File::NULL, err: File::NULL)
    next unless ok_status && File.exist?(page_pdf)
    size = File.size(page_pdf)
    if size > 50 * 1024 * 1024
      puts "  page #{page}: SKIP (#{size / 1024 / 1024}MB > 50MB)"
      File.delete(page_pdf) rescue nil
      next
    end

    begin
      md = ocr.ocr_pdf(page_pdf, num_pages: 1)
      ok << page
    rescue StandardError => e
      failed << page
    end
    File.delete(page_pdf) rescue nil
  end

  puts "  OK: #{ok.size}/#{total_pages} pages"
  puts "  FAILED: #{failed.size}/#{total_pages} pages: #{failed.inspect}"
end
