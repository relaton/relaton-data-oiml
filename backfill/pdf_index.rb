# frozen_string_literal: true

# One-off: scrape the OIML Bulletin online-bulletin listing for every PDF URL.
# NOT maintained. PDF paths on oiml.org are inconsistent
# (/bulletin/pdf/..., /oiml-bulletin/pdf/..., _april_/_july_/_october_/_jan_
# month-name variations) — never construct URLs, always scrape actual hrefs.
#
# Run:
#   bundle exec ruby backfill/pdf_index.rb
#
# Output: backfill/cache/pdf_index.yaml — list of {year, issue, url, label}

$LOAD_PATH.unshift(File.expand_path("../lib", __dir__))
require "oiml_fetcher"
require "yaml"
require "fileutils"

module BulletinBackfill
  class PdfIndex
    LISTING_URL = "#{OimlFetcher::BASE_URL}/en/publications/oiml-bulletin/online-bulletin"

    attr_reader :entries

    def initialize(http_backend: OimlFetcher::Http.backend)
      @http = http_backend
      @entries = []
    end

    def scrape
      doc = Nokogiri::HTML(@http.get(LISTING_URL))
      doc.css("a[href]").each do |a|
        href = a["href"]
        next unless href && href.end_with?(".pdf")

        label = a.text.strip
        @entries << { "url" => absolutize(href), "label" => label }.merge(parse_slug(label, href))
      end
      @entries.uniq! { |e| e["url"] }
      self
    end

    private

    # "2024-01" -> {year: 2024, issue: "01"}; PDFs without a clean slug get nil.
    # Issue numbering is quarterly: 01/04/07/10 in PDF filenames map to 1/2/3/4.
    def parse_slug(label, href)
      m = (label || href).match(/(20\d\d|19\d\d)[-_]?(0[1-4]|jan|apr|jul|oct|april|july|october)/i)
      return {} unless m

      { "year" => m[1].to_i, "issue" => MONTH_MAP.fetch(m[2].downcase) }
    end

    # PDF labels use MONTH numbers (01/04/07/10) — convert to the quarterly
    # issue numbering (01/02/03/04) used in HTML slugs and docids.
    MONTH_MAP = {
      "01" => "01", "04" => "02", "07" => "03", "10" => "04",
      "jan" => "01", "apr" => "02", "jul" => "03", "oct" => "04",
      "april" => "02", "july" => "03", "october" => "04",
    }.freeze

    def absolutize(href)
      return href if href.start_with?("http")

      "#{OimlFetcher::BASE_URL}#{href.start_with?('/') ? '' : '/'}#{href}"
    end
  end
end

if $PROGRAM_NAME == __FILE__
  entries = BulletinBackfill::PdfIndex.new.scrape.entries
  out = File.expand_path("cache/pdf_index.yaml", __dir__)
  FileUtils.mkdir_p(File.dirname(out))
  File.write(out, entries.to_yaml, encoding: "UTF-8")
  puts "Indexed #{entries.size} PDFs -> #{out}"
  with_slug = entries.count { |e| e["year"] }
  puts "With parsed year/issue: #{with_slug} / #{entries.size}"
end
