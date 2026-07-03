# frozen_string_literal: true

# One-off: verify docx-spine entries against GLM OCR of the actual Bulletin
# PDFs. NOT maintained.
#
# For each issue, OCR the PDF and parse the SOMMAIRE (table of contents)
# section. Compare with the docx-spine entries for that issue. Report:
#   - matches (docx entry confirmed by OCR)
#   - gaps (OCR has an article, docx doesn't)
#   - extras (docx has an article, OCR doesn't)
#   - bonus (OCR captured author/page that docx missed)
#
# Run:
#   bundle exec ruby backfill/verify_against_ocr.rb <pdf_url> <year> <bulletin_no> <num_pages>

$LOAD_PATH.unshift(File.expand_path("../lib", __dir__))
require "oiml_fetcher"
require "yaml"

module BulletinBackfill
  class VerifyAgainstOcr
    SOMMAIRE_BOUNDARIES = %w[SOMMAIRE SUMMARY CONTENTS].freeze

    attr_reader :result

    def initialize(year:, bulletin_no:, docx_path:, ocr_md:)
      @year = year
      @bulletin_no = bulletin_no
      @docx_path = docx_path
      @ocr_md = ocr_md
    end

    def verify
      docx_entries = load_docx_entries
      ocr_entries = parse_sommaire

      @result = {
        docx_count: docx_entries.size,
        ocr_count: ocr_entries.size,
        matches: [],
        gaps_in_docx: [],
        extras_in_docx: [],
        bonus_metadata: [],
      }

      ocr_entries.each do |ocr|
        match = docx_entries.find { |d| titles_match?(d["title"], ocr[:title]) }
        if match
          @result[:matches] << { title: ocr[:title], docx_seq: match["sequence"] }
          if ocr[:author] && !match["author"]
            @result[:bonus_metadata] << { kind: "author", seq: match["sequence"],
                                          ocr_value: ocr[:author] }
          end
          if ocr[:page] && !match["page"]
            @result[:bonus_metadata] << { kind: "page", seq: match["sequence"],
                                          ocr_value: ocr[:page] }
          end
        else
          @result[:gaps_in_docx] << ocr
        end
      end

      docx_titles = docx_entries.map { |d| normalize(d["title"]) }
      @result[:extras_in_docx] = docx_entries.reject do |d|
        ocr_entries.any? { |o| titles_match?(d["title"], o[:title]) }
      end.map { |d| { seq: d["sequence"], title: d["title"] } }

      self
    end

    private

    # Parse the OCR markdown's SOMMAIRE / SUMMARY / CONTENTS section into
    # { title:, author:, page: } entries.
    def parse_sommaire
      start_idx = nil
      @ocr_md.lines.each_with_index do |line, i|
        next unless SOMMAIRE_BOUNDARIES.any? { |b| line =~ /#{b}/i }

        start_idx = i + 1
        break
      end
      return [] unless start_idx

      # Section ends at the first # header (article body start) or DOCUMENTATION.
      entries = []
      current_title = nil
      @ocr_md.lines[start_idx..].each do |line|
        break if line.start_with?("# ") && !line.start_with?("# BULLETIN")
        # Skip empty and image lines.
        next if line.strip.empty? || line.include?("![](")

        # Bullet-style entries often span multiple lines (title, then byline,
        # then page number on its own). Treat each meaningful block.
        page_m = line.match(/\s(\d+)\s*\z/)
        author_m = line.match(/par\s+(.+?)\s*\(([^)]+)\)/i) ||
                   line.match(/by\s+(.+?)\s*\(([^)]+)\)/i)
        if page_m
          stripped = line.sub(/\s#{page_m[1]}\s*\z/, "").strip
          entries << { title: stripped, author: nil, page: page_m[1].to_i }
        elsif author_m
          entries.last[:author] = "#{author_m[1]} (#{author_m[2]})" if entries.last
        elsif line =~ /\A[^\s#].*\S/
          stripped = line.strip.gsub(/^[-*]\s+/, "")
          entries << { title: stripped, author: nil, page: nil } unless stripped.empty?
        end
      end
      entries
    end

    def load_docx_entries
      all = YAML.load_file(@docx_path)
      all.select { |e| e["year"] == @year && e["bulletin_no"] == @bulletin_no }
          .sort_by { |e| e["sequence"] }
    end

    def titles_match?(a, b)
      na, nb = normalize(a), normalize(b)
      na == nb || na.include?(nb) || nb.include?(na) ||
        (na.size > 15 && nb.size > 15 && na[0, 50] == nb[0, 50])
    end

    def normalize(s)
      return "" if s.nil?

      s.downcase.gsub(/[àâä]/, "a").gsub(/[éèêë]/, "e").gsub(/[îï]/, "i")
       .gsub(/[ôö]/, "o").gsub(/[ûüù]/, "u").gsub(/[ç]/, "c")
       .gsub(/[^a-z0-9 ]/, "").squeeze(" ").strip
    end
  end
end

if $PROGRAM_NAME == __FILE__
  pdf = ARGV[0]
  year = ARGV[1]&.to_i
  bulletin_no = ARGV[2]&.to_i
  num_pages = (ARGV[3] || 60).to_i
  abort "usage: verify_against_ocr.rb <pdf_url_or_path> <year> <bulletin_no> <num_pages>" unless pdf && year && bulletin_no

  $LOAD_PATH.unshift(File.expand_path("../backfill", __dir__))
  load "glm_ocr.rb"
  require "fileutils"
  FileUtils.mkdir_p("backfill/cache")

  puts "OCR'ing #{pdf} (#{num_pages} pages)..."
  ocr = BulletinBackfill::GlmOcr.new
  md = ocr.ocr_pdf(pdf, num_pages: num_pages)
  cache_path = "backfill/cache/verify_#{year}_no#{bulletin_no}.md"
  File.write(cache_path, md)

  result = BulletinBackfill::VerifyAgainstOcr.new(
    year: year, bulletin_no: bulletin_no,
    docx_path: "backfill/cache/docx_articles.yaml", ocr_md: md,
  ).verify.result

  puts "\n=== #{year} no.#{bulletin_no} verification ==="
  puts "docx entries: #{result[:docx_count]}, OCR SOMMAIRE entries: #{result[:ocr_count]}"
  puts "matches: #{result[:matches].size}"
  puts "in OCR but not docx (gaps): #{result[:gaps_in_docx].size}"
  result[:gaps_in_docx].first(5).each { |g| puts "  - #{g[:title][0, 90]}" } if result[:gaps_in_docx].any?
  puts "in docx but not OCR (extras): #{result[:extras_in_docx].size}"
  result[:extras_in_docx].first(5).each { |g| puts "  - [#{g[:seq]}] #{g[:title][0, 90]}" } if result[:extras_in_docx].any?
  puts "bonus metadata from OCR: #{result[:bonus_metadata].size}"
  result[:bonus_metadata].first(5).each { |b| puts "  - #{b[:kind]}: #{b[:ocr_value]}" } if result[:bonus_metadata].any?

  summary = "backfill/cache/verify_summary.yaml"
  data = (File.exist?(summary) ? YAML.load_file(summary) : []) << {
    "year" => year, "bulletin_no" => bulletin_no,
    "docx_count" => result[:docx_count], "ocr_count" => result[:ocr_count],
    "matches" => result[:matches].size, "gaps" => result[:gaps_in_docx].size,
    "extras" => result[:extras_in_docx].size, "bonus" => result[:bonus_metadata].size,
  }
  File.write(summary, data.to_yaml)
end
