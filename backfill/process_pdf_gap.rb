# frozen_string_literal: true

# One-off: process the missing 2024-01 and 2024-04 PDFs into 4-tier
# bulletin records. NOT maintained.
#
# These issues fall in the gap between the docx end (mid-2023) and HTML
# start (2025-02). TODO 01 closed 2024-07 and 2024-10 via HTML; this
# closes the remaining born-digital PDFs.
#
# Run:
#   bundle exec ruby backfill/process_pdf_gap.rb

$LOAD_PATH.unshift(File.expand_path("../lib", __dir__))
require "oiml_fetcher"
require "open3"
require "open-uri"
require "fileutils"
require "yaml"

module BulletinBackfill
  class ProcessPdfGap
    PDFS = {
      "2024-01" => "https://www.oiml.org/en/publications/oiml-bulletin/pdf/oiml_bulletin_jan_2024.pdf",
      "2024-04" => "https://www.oiml.org/en/publications/oiml-bulletin/pdf/oiml_bulletin_april_2024.pdf",
    }.freeze

    # Section labels appear as bare lowercase lines in the TOC (e.g. "technique",
    # "evolutions", "update", "chiang mai"). Articles under them are tagged.
    SECTION_LABELS = %w[technique evolutions update focus "chiang mai" editorial].freeze

    attr_reader :stats

    def initialize(data_dir:, store: nil)
      @data_dir = data_dir
      @store = store || OimlFetcher::YamlStore.new(data_dir)
      @cache_dir = File.expand_path("cache/pdfs", __dir__)
      @stats = Hash.new(0)
    end

    def run
      PDFS.each do |slug, url|
        process_issue(slug, url)
      end
      patch_bulletin
      self
    end

    private

    def process_issue(slug, url)
      path = download(url, slug)
      contents_text = extract_contents_page(path)
      entries = parse_contents(contents_text)
      @stats[:issues] += 1
      @stats[:articles] += entries.size

      year = slug[0, 4].to_i
      month = slug[5, 2]
      roman = extract_roman(path)
      issue_no = month_to_issue(month)

      write_volume(year, roman)
      write_issue(slug, year, month, roman, entries)
      entries.each_with_index { |e, idx| write_article(slug, year, month, roman, idx + 1, e, url) }
      warn "  #{slug}: #{entries.size} articles, volume #{roman}"
    end

    def download(url, slug)
      FileUtils.mkdir_p(@cache_dir)
      path = File.join(@cache_dir, "#{slug}.pdf")
      return path if File.exist?(path)

      URI.open(url, "User-Agent" => "relaton-data-oiml") do |r|
        File.binwrite(path, r.read)
      end
      path
    end

    def extract_contents_page(pdf_path)
      # The Contents page is page 3 in 2024 PDFs.
      out, = Open3.capture2("pdftotext", "-layout", "-f", "3", "-l", "3", pdf_path, "-")
      out
    end

    # Parse the contents page into [{title:, author:, page:}] entries.
    def parse_contents(text)
      entries = []
      lines = text.lines.map(&:rstrip)
      current_section = nil
      i = 0
      while i < lines.size
        line = lines[i]
        stripped = line.strip
        i += 1
        next if stripped.empty?

        # Section label (lowercase, no leading digit, matches known set)
        if SECTION_LABELS.any? { |l| stripped.downcase == l.gsub('"', '') }
          current_section = stripped.downcase
          next
        end

        # TOC entry: "<page> <title...>"
        m = stripped.match(/\A(\d+)\s+(.+)\z/)
        next unless m

        page = m[1].to_i
        title = m[2].strip
        # Continuation: subsequent non-digit-led lines belong to the same entry
        # (continuation of title, or author byline).
        author = nil
        while i < lines.size
          nxt = lines[i].strip
          break if nxt.empty?
          break if nxt.match?(/\A\d+\s+/)
          break if SECTION_LABELS.any? { |l| nxt.downcase == l.gsub('"', '') }

          # If the line is in Title Case (looks like a title continuation),
          # append it. If it looks like a person name, treat as author.
          if looks_like_author?(nxt)
            author = nxt
          else
            title = "#{title} #{nxt}".squeeze(" ")
          end
          i += 1
        end
        title = title.squeeze(" ").strip
        entries << { title: title, author: author, page: page, section: current_section }
      end
      entries
    end

    def looks_like_author?(line)
      # Author bylines in the 2024 Contents are plain "First Last" or
      # "F. Last, F. Other" forms — no digits, short, primarily letters
      # with commas/periods for initials.
      return false unless line.match?(/\A[A-Z]/)
      return false if line.length > 100

      word_count = line.split.size
      word_count.between?(1, 8) && line.match?(/\A[A-Z][A-Za-z .,\-']+\z/)
    end

    def extract_roman(pdf_path)
      # "VOLUME LXV • NUMBER 1" appears on page 1. The cover uses letter-
      # spacing (e.g. "V OLUME LXV"), so strip ALL whitespace before matching.
      out, = Open3.capture2("pdftotext", "-f", "1", "-l", "1", pdf_path, "-")
      m = out.gsub(/\s+/, "").match(/VOLUME([IVXLCDM]+)/i)
      m && m[1].upcase
    end

    def month_to_issue(m)
      { "01" => 1, "04" => 2, "07" => 3, "10" => 4 }.fetch(m)
    end

    def write_volume(year, roman)
      path = File.join(@data_dir, "bulletin_#{year}.yaml")
      existing = File.exist?(path) ? YAML.safe_load(File.read(path)) : nil
      hash = existing || {
        "id" => "Bulletin-#{year}",
        "type" => "journal",
        "title" => [localized("OIML Bulletin, Volume #{roman} (#{year})")],
        "docidentifier" => [{ "content" => "OIML Bulletin #{year}", "type" => "OIML", "primary" => true }],
        "language" => ["eng"], "script" => ["Latn"],
        "series" => [series_hash],
        "ext" => { "doctype" => { "content" => "volume" }, "flavor" => "oiml" },
      }
      hash["extent"] = [{ "locality" => [{ "type" => "volume", "reference_from" => roman }] }] if roman
      hash["date"] = [{ "type" => "published", "from" => "#{year}-01-01" }]
      hash["copyright"] = [{
        "from" => year.to_s,
        "owner" => [{ "organization" => OimlFetcher.oiml_org_hash }],
      }]
      @store.write("bulletin_#{year}", hash)
    end

    def write_issue(slug, year, month, roman, entries)
      issue_no = month_to_issue(month)
      article_docids = entries.each_with_index.map do |_, i|
        "OIML Bulletin #{slug}-#{format('%02d', i + 1)}"
      end
      hash = {
        "id" => "Bulletin-#{slug}",
        "type" => "journal",
        "title" => [localized("OIML Bulletin, Volume #{roman}, Number #{issue_no} (#{year})")],
        "docidentifier" => [{ "content" => "OIML Bulletin #{slug}", "type" => "OIML", "primary" => true }],
        "language" => ["eng"], "script" => ["Latn"],
        "series" => [series_hash],
        "extent" => [{ "locality" => [
          { "type" => "volume", "reference_from" => roman },
          { "type" => "issue", "reference_from" => issue_no.to_s },
        ] }],
        "date" => [{ "type" => "published", "from" => "#{year}-#{month}-01" }],
        "copyright" => [{ "from" => year.to_s,
                          "owner" => [{ "organization" => OimlFetcher.oiml_org_hash }] }],
        "contributor" => [OimlFetcher.oiml_publisher_contributor],
        "relation" => [parent_relation("OIML Bulletin #{year}")] +
                      article_docids.map { |d| child_relation(d) },
        "ext" => { "doctype" => { "content" => "issue" }, "flavor" => "oiml" },
      }
      @store.write("bulletin_#{slug}", hash)
    end

    def write_article(slug, year, month, roman, seq, entry, issue_url)
      issue_no = month_to_issue(month)
      contributors = [OimlFetcher.oiml_publisher_contributor]
      if entry[:author]
        entry[:author].split(/,| and /).map(&:strip).each do |name|
          next if name.empty?

          contributors << {
            "role" => [{ "type" => "author" }],
            "person" => { "name" => { "completename" => { "content" => name } } },
          }
        end
      end
      hash = {
        "id" => "Bulletin-#{slug}-#{format('%02d', seq)}",
        "type" => "article",
        "title" => [{ "language" => "eng", "script" => "Latn",
                      "content" => entry[:title], "type" => "main" }],
        "docidentifier" => [{ "content" => "OIML Bulletin #{slug}-#{format('%02d', seq)}",
                              "type" => "OIML", "primary" => true }],
        "date" => [{ "type" => "published", "from" => "#{year}-#{month}-01" }],
        "contributor" => contributors,
        "language" => ["eng"], "script" => ["Latn"],
        "series" => [series_hash],
        "extent" => [{ "locality" => [
          { "type" => "volume", "reference_from" => roman },
          { "type" => "issue", "reference_from" => issue_no.to_s },
          { "type" => "page", "reference_from" => entry[:page].to_s },
        ] }],
        "source" => [OimlFetcher::Source.url(issue_url)],
        "relation" => [{
          "type" => "includedIn",
          "bibitem" => { "docidentifier" => [{ "content" => "OIML Bulletin #{slug}", "type" => "OIML" }] },
        }],
        "ext" => { "doctype" => { "content" => "article" }, "flavor" => "oiml",
                   "provenance" => ["pdf"], "section" => entry[:section] },
      }
      @store.write("bulletin_#{slug}-#{format('%02d', seq)}", hash)
    end

    def patch_bulletin
      path = File.join(@data_dir, "bulletin.yaml")
      return unless File.exist?(path)

      hash = YAML.safe_load(File.read(path))
      existing = (hash["relation"] || []).select { |r| r["type"] == "hasPart" }
                                          .map { |r| r["bibitem"]["docidentifier"].first["content"] }
      targets = (existing + %w[2024]).uniq.sort
      other = (hash["relation"] || []).reject { |r| r["type"] == "hasPart" }
      hash["relation"] = other + targets.map { |d| child_relation(d) }
      @store.write("bulletin", hash)
    end

    def localized(content)
      { "language" => "eng", "script" => "Latn", "content" => content, "type" => "main" }
    end

    def series_hash
      { "title" => [{ "content" => "OIML Bulletin", "language" => "eng",
                      "script" => "Latn", "format" => "text/plain" }] }
    end

    def parent_relation(docid)
      { "type" => "partOf", "bibitem" => { "docidentifier" => [{ "content" => docid, "type" => "OIML" }] } }
    end

    def child_relation(docid)
      { "type" => "hasPart", "bibitem" => { "docidentifier" => [{ "content" => docid, "type" => "OIML" }] } }
    end
  end
end

if $PROGRAM_NAME == __FILE__
  r = BulletinBackfill::ProcessPdfGap.new(data_dir: File.expand_path("../data", __dir__)).run
  puts "PDF gap processing:"
  puts "  issues: #{r.stats[:issues]}"
  puts "  articles: #{r.stats[:articles]}"
end
