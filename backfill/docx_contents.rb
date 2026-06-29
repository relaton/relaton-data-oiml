# frozen_string_literal: true

# One-off: parse contents-of-oiml-bulletins-2023-07-24.docx into per-entry
# candidates. NOT maintained. NOT in lib/, CI, or cron.
#
# Source structure: one <w:tbl> with columns Year | Bulletin No. | Contents.
# The Contents cell holds one <w:p> per article (the paragraph boundary is
# the entry delimiter — collapsing paragraphs corrupts the data).
#
# Run:
#   bundle exec ruby backfill/docx_contents.rb [path/to/contents.docx]
#
# Output: backfill/cache/docx_articles.yaml — flat list of candidates:
#   - year:, bulletin_no:, sequence:, title:, author:, country:, category:, raw:
#
# Caveats handled here:
#   - blank Year cells carry-forward from the previous row
#   - "1964." -> 1964 normalization
#   - "par <NAME> (COUNTRY)" / "by <NAME>, <COUNTRY>" byline extraction
#   - section headers (DOCUMENTATION, INFORMATIONS) tagged category: section

require "rexml/document"
require "yaml"
require "fileutils"

module BulletinBackfill
  class DocxContents
    BYLINE_PATTERNS = [
      /,\s+par\s+([^,(]+?)\s*\(([^)]+)\)\.?\s*\z/i,
      /,\s+par\s+([^,(]+?)\s*\z/i,
      /,\s+by\s+([^,(]+?)\s*\(([^)]+)\)\.?\s*\z/i,
      /,\s+by\s+([^,(]+?)\s*\z/i,
    ].freeze

    SECTION_HEADERS = %w[DOCUMENTATION INFORMATION INFORMATIONS].freeze

    attr_reader :entries

    def initialize(path)
      @path = path
      @entries = []
    end

    def parse
      xml = unzip_document_xml
      last_year = nil
      sequence_by_issue = Hash.new(0)

      rows(xml).each do |cells|
        next if cells.empty?
        next unless cells.length >= 3

        year = normalize_year(cell_text(cells[0])) || last_year
        contents_xml = cells[2]
        next unless year && contents_xml

        last_year = year
        bulletin_no = parse_bulletin_no(cell_text(cells[1]))
        issue_key = [year, bulletin_no]

        paragraphs(contents_xml).each do |raw|
          next if raw.empty?

          sequence_by_issue[issue_key] += 1
          @entries << build_entry(year, bulletin_no, sequence_by_issue[issue_key], raw)
        end
      end
      self
    end

    private

    def rows(xml)
      xml.scan(/<w:tr\b.*?<\/w:tr>/m).map do |row|
        row.scan(/<w:tc\b.*?<\/w:tc>/m)
      end
    end

    def cell_text(cell_xml)
      cell_xml.scan(%r{<w:t[ >].*?</w:t>}m).map { |t| t.gsub(/<[^>]+>/, "") }
              .join.strip.gsub(/\s+/, " ")
    end

    def build_entry(year, bulletin_no, sequence, raw)
      category = SECTION_HEADERS.any? { |h| raw.start_with?(h) || raw == h } ? "section" : "article"
      title, author, country = split_byline(raw)
      {
        "year" => year,
        "bulletin_no" => bulletin_no,
        "sequence" => format("%02d", sequence),
        "title" => title,
        "author" => author,
        "country" => country,
        "category" => category,
        "raw" => raw,
      }
    end

    # Strip trailing "par/by NAME (COUNTRY)" byline. Returns [title, author, country].
    def split_byline(raw)
      BYLINE_PATTERNS.each do |re|
        m = re.match(raw)
        next unless m

        title = m.pre_match.sub(/[,.;:\s]+\z/, "").strip
        author = m[1].strip
        country = m[2] && m[2].strip
        return [title, author, country]
      end
      [raw, nil, nil]
    end

    def normalize_year(text)
      return nil if text.nil? || text.strip.empty?

      m = /\A(\d{4})\.?\z/.match(text.strip)
      m ? m[1].to_i : nil
    end

    def parse_bulletin_no(text)
      return nil if text.nil?

      m = /(\d+)/.match(text)
      m && m[1].to_i
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
  puts "Parsed #{entries.size} entries -> #{out}"
  puts "Year range: #{years.min}-#{years.max}" unless years.empty?
  puts "With author: #{entries.count { |e| e["author"] }} / #{entries.size}"
end
