# frozen_string_literal: true

# One-off: parse contents-of-oiml-bulletins-2023-07-24.docx into per-entry
# candidates. NOT maintained. NOT in lib/, CI, or cron.
#
# Source structure: one <w:tbl> with columns Year | Bulletin No. | Contents.
# The Contents cell holds one <w:p> per article (the paragraph boundary is
# the entry delimiter — collapsing paragraphs corrupts the data).
#
# Three Bulletin-No. column formats coexist in the docx:
#   1960-1993: cumulative bulletin number, e.g. "130." or "132. – 133."
#   1994:      transition format, e.g. "april_1994"
#   1995+:     "Volume XXXVI • Number 1 • January 1995" (rich metadata)
#
# Run:
#   bundle exec ruby backfill/docx_contents.rb [path/to/contents.docx]
#
# Output: backfill/cache/docx_articles.yaml — flat list of candidates.

require "yaml"
require "fileutils"

module BulletinBackfill
  class DocxContents
    BYLINE_PATTERNS = [
      # French: ", par NAME (COUNTRY)."  — most common early era form
      /,\s+par\s+(.+?)\s*\(([^)]+?)\)\.?\s*\z/i,
      # French: ", par NAME, COUNTRY" — no parens
      /,\s+par\s+(.+?),\s*([A-Z][^,()]+?)\.?\s*\z/,
      # French: ", par NAME." — no country
      /,\s+par\s+(.+?)\s*\.\z/i,
      # English: "by NAME (COUNTRY)." — with or without leading comma
      /,?\s+by\s+(.+?)\s*\(([^)]+?)\)\.?\s*\z/i,
      # English: "by NAME, COUNTRY"
      /,?\s+by\s+(.+?),\s*([A-Z][^,()]+?)\.?\s*\z/,
      # English: " - NAME (COUNTRY)"
      /\s-\s+(.+?)\s*\(([^)]+?)\)\.?\s*\z/,
      # English: " - NAME, COUNTRY"
      /\s-\s+(.+?),\s*([A-Z][^,()]+?)\.?\s*\z/,
      # English: " - NAME"
      /\s-\s+([A-Z][^.()]{2,60})\s*\z/,
    ].freeze

    SECTION_MARKERS = %w[DOCUMENTATION INFORMATION INFORMATIONS ■].freeze

    CUMULATIVE_RE = /\A(\d+)\.(?:\s*[–-]\s*(\d+)\.)?\s*\z/
    TRANSITION_RE = /\A([a-z]+)_(\d{4})\z/i
    MODERN_RE = /Volume\s*([IVXLCDM]+)\s*[•·.\-]\s*(?:Number|Num(?:é|e)ro)\s*(\d+|[IVXLCDM]+)\s*[•·.\-]?\s*([A-Za-zéû]+)\s+(\d{4})/i

    MONTH_MAP = {
      "january" => 1, "jan" => 1, "april" => 4, "apr" => 4,
      "july" => 7, "jul" => 7, "october" => 10, "oct" => 10,
      "janvier" => 1, "avril" => 4, "juillet" => 7, "octobre" => 10,
    }.freeze

    attr_reader :entries

    def initialize(path)
      @path = path
      @entries = []
    end

    def parse
      xml = unzip_document_xml
      last_year = nil
      current_desc = nil
      sequence_by_issue = Hash.new(0)

      rows(xml).each do |cells|
        next unless cells.length >= 3

        # Year can come from cell0 OR from cell1's modern format ("... January 2019")
        new_desc = parse_issue_descriptor(cell_text(cells[1]))
        year = normalize_year(cell_text(cells[0])) ||
               (new_desc && new_desc[:year]) || last_year
        current_desc = new_desc if new_desc
        contents_xml = cells[2]
        next unless year && contents_xml

        last_year = year
        paras = paragraphs(contents_xml)
        next if paras.empty?

        issue_key = [year, current_desc && (current_desc[:bulletin_no] || current_desc[:issue_no])]
        paras.each do |raw|
          next if raw.empty?

          sequence_by_issue[issue_key] += 1
          @entries << build_entry(year, current_desc, sequence_by_issue[issue_key], raw)
        end
      end
      self
    end

    private

    def build_entry(year, desc, sequence, raw)
      desc ||= {}
      {
        "year" => year,
        "bulletin_no" => desc[:bulletin_no],
        "volume_roman" => desc[:volume_roman],
        "issue_no" => desc[:issue_no],
        "month" => desc[:month],
        "sequence" => format("%02d", sequence),
        "title" => split_byline(raw)[0],
        "author" => split_byline(raw)[1],
        "country" => split_byline(raw)[2],
        "category" => section?(raw) ? "section" : "article",
        "raw" => raw,
      }
    end

    def section?(raw)
      SECTION_MARKERS.any? { |m| raw.start_with?(m) }
    end

    def parse_issue_descriptor(text)
      return nil if text.nil? || text.strip.empty?

      text = text.strip
      if (m = MODERN_RE.match(text))
        month = MONTH_MAP[m[3].downcase]
        issue_no = m[2].match?(/\A\d+\z/) ? m[2].to_i : roman_to_int(m[2])
        { volume_roman: m[1].upcase, issue_no: issue_no, month: month,
          bulletin_no: issue_no, year: m[4].to_i }
      elsif (m = TRANSITION_RE.match(text))
        month = MONTH_MAP[m[1].downcase]
        issue_no = month && (month / 3).ceil + (month % 3 == 1 ? 0 : 0)
        # jan(1)->1, apr(4)->2, jul(7)->3, oct(10)->4
        issue_no = month && { 1 => 1, 4 => 2, 7 => 3, 10 => 4 }[month]
        { issue_no: issue_no, month: month, bulletin_no: issue_no }
      elsif (m = CUMULATIVE_RE.match(text))
        { bulletin_no: m[1].to_i }
      end
    end

    def roman_to_int(s)
      map = { "M" => 1000, "D" => 500, "C" => 100, "L" => 50,
              "X" => 10, "V" => 5, "I" => 1 }
      s.upcase.chars.inject(0) { |a, c| a + map.fetch(c, 0) }
    end

    def split_byline(raw)
      BYLINE_PATTERNS.each do |re|
        m = re.match(raw)
        next unless m

        title = m.pre_match.sub(/[,.;:\s\-•]+\z/, "").strip
        author = m[1].strip
        country = m[2] && m[2].strip
        return [title, author, country] unless title.empty?
      end
      [raw, nil, nil]
    end

    def normalize_year(text)
      return nil if text.nil? || text.strip.empty?

      m = /\A(\d{4})\.?\z/.match(text.strip)
      m ? m[1].to_i : nil
    end

    def rows(xml)
      xml.scan(/<w:tr\b.*?<\/w:tr>/m).map do |row|
        row.scan(/<w:tc\b.*?<\/w:tc>/m)
      end
    end

    def cell_text(cell_xml)
      cell_xml.scan(%r{<w:t[ >].*?</w:t>}m).map { |t| t.gsub(/<[^>]+>/, "") }
              .join.strip.gsub(/\s+/, " ")
    end

    def paragraphs(cell_xml)
      cell_xml.split("</w:p>").map do |p|
        texts = p.scan(%r{<w:t[ >].*?</w:t>}m).map { |t| t.gsub(/<[^>]+>/, "") }
        texts.join.strip.gsub(/\s+/, " ")
      end.reject(&:empty?)
    end

    def unzip_document_xml
      require "open3"
      output, status = Open3.capture2("unzip", "-p", @path, "word/document.xml")
      raise "unzip failed for #{@path}" unless status.success?

      output
    end
  end
end

if $PROGRAM_NAME == __FILE__
  path = ARGV[0] || "backfill/cache/contents-of-oiml-bulletins-2023-07-24.docx"
  abort "docx not found: #{path}" unless File.exist?(path)

  entries = BulletinBackfill::DocxContents.new(path).parse.entries
  out = File.expand_path("cache/docx_articles.yaml", __dir__)
  FileUtils.mkdir_p(File.dirname(out))
  File.write(out, entries.to_yaml, encoding: "UTF-8")
  years = entries.map { |e| e["year"] }.compact
  with_roman = entries.count { |e| e["volume_roman"] }
  with_issue = entries.count { |e| e["issue_no"] }
  puts "Parsed #{entries.size} entries -> #{out}"
  puts "Year range: #{years.min}-#{years.max}" unless years.empty?
  puts "With volume_roman (1995+): #{with_roman}"
  puts "With issue_no: #{with_issue}"
  puts "With author: #{entries.count { |e| e['author'] }} / #{entries.size}"
end
