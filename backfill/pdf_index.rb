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

    # Map a PDF URL/label to (year, issue). Patterns:
    #   - born-digital: "oiml_bulletin_<month>_YYYY.pdf" (month name in any order)
    #   - scanned era single: "YYYY-bulletin-N.pdf" (N is cumulative)
    #   - scanned era range: "YYYY-bulletin-N-M.pdf" (two consecutive issues in one PDF)
    def parse_slug(label, href)
      basename = File.basename(href || "")
      # Scanned-era range: "1993-bulletin-132-133.pdf"
      if (m = basename.match(/\A(\d{4})-bulletin-(\d+)-(\d+)\.pdf\z/i))
        year = m[1].to_i
        first, last = m[2].to_i, m[3].to_i
        issue_first = within_year_issue_for(year, first)
        issue_last = within_year_issue_for(year, last)
        return { "year" => year, "issue" => "#{issue_first}-#{issue_last}",
                 "bulletin_no" => "#{first}-#{last}" }
      end
      # Scanned-era single: "1961-bulletin-6.pdf"
      if (m = basename.match(/\A(\d{4})-bulletin-(\d+)\.pdf\z/i))
        year = m[1].to_i
        cumulative = m[2].to_i
        issue = within_year_issue_for(year, cumulative)
        return { "year" => year, "issue" => issue, "bulletin_no" => cumulative }
      end
      # Born-digital: "<month>_YYYY" or "YYYY-MM"
      m = basename.match(/(january|february|march|april|may|june|july|august|september|october|november|december|jan|apr|jul|oct|april)[_-](\d{4})/i)
      if m
        month_name = m[1].downcase
        year = m[2].to_i
        return { "year" => year, "issue" => MONTH_MAP.fetch(month_name) }
      end
      m = (label || href).match(/(20\d\d|19\d\d)[-_]?(0[1-4]|01|04|07|10|jan|apr|jul|oct|april|july|october)/i)
      return {} unless m

      { "year" => m[1].to_i, "issue" => MONTH_MAP.fetch(m[2].downcase) }
    end

    # Look up which within-year issue number corresponds to a cumulative
    # bulletin_no in a given year. Loads docx_articles.yaml once.
    CUMULATIVE_MAPPING = nil # set lazily on first call

    def within_year_issue_for(year, cumulative)
      @@cumulative_mapping ||= begin
        path = File.expand_path("cache/docx_articles.yaml", __dir__)
        if File.exist?(path)
          entries = YAML.load_file(path)
          per_year = entries.group_by { |e| e["year"] }
          per_year.transform_values do |es|
            nos = es.map { |e| e["bulletin_no"] }.compact.uniq.sort
            nos.each_with_index.to_h { |n, i| [n, i + 1] }
          end
        else
          {}
        end
      end
      @@cumulative_mapping.dig(year, cumulative) || 1
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
