# frozen_string_literal: true

# One-off: enrich existing bulletin article records with page numbers and
# authors parsed from the born-digital PDF text extractions in
# ~/src/oimlsmart/bulletin-data/. NOT maintained.
#
# For each <year>/<issue>/ocr.md, find the Contents/SOMMAIRE section and
# extract (title, author, page) tuples. Match against existing
# data/bulletin_<year>-<issue>-*.yaml records by normalized title and patch:
#   - extent.locality: page (when missing)
#   - contributor: person author (when missing and OCR-confident)
#   - ext.provenance: include "pdf"
#
# Run:
#   bundle exec ruby backfill/enrich_from_pdf_text.rb

$LOAD_PATH.unshift(File.expand_path("../lib", __dir__))
require "oiml_fetcher"
require "yaml"
require "digest"

module BulletinBackfill
  class EnrichFromPdfText
    SECTION_LABELS = %w[technique evolutions update focus "chiang mai" editorial
                        information news documentation].freeze

    attr_reader :stats

    def initialize(data_dir:, bulletin_data_root:)
      @data_dir = data_dir
      @root = bulletin_data_root
      @stats = Hash.new(0)
    end

    def run
      Dir[File.join(@root, "[0-9][0-9][0-9][0-9]", "[0-9][0-9]", "ocr.md")].sort.each do |path|
        slug = path[%r{/(\d{4}/\d{2})/ocr\.md\z}, 1]&.tr("/", "-")
        next unless slug

        enrich_issue(slug, path)
      end
      self
    end

    private

    def enrich_issue(slug, ocr_path)
      entries = parse_contents(File.read(ocr_path, encoding: "UTF-8"))
      return @stats[:issues_no_contents] += 1 if entries.empty?

      data_yaml = File.join(@data_dir, "bulletin_#{slug}.yaml")
      unless File.exist?(data_yaml)
        @stats[:issues_no_data] += 1
        return
      end

      # Walk article records for this issue and patch matching entries.
      patched = 0
      Dir[File.join(@data_dir, "bulletin_#{slug}-??.yaml")].sort.each do |art_path|
        art = YAML.safe_load(File.read(art_path, encoding: "UTF-8"))
        next unless art

        art_title = art.dig("title", 0, "content")
        next unless art_title

        match = entries.find { |e| titles_match?(art_title, e[:title]) }
        next unless match

        changed = patch_article!(art, match)
        if changed
          write_yaml(art_path, art)
          patched += 1
          @stats[:articles_enriched] += 1
        end
      end
      @stats[:issues_enriched] += 1 if patched.positive?
    end

    # Returns true if any field was changed.
    def patch_article!(art, match)
      changed = false
      # Add page number to extent if missing.
      if match[:page]
        extent = (art["extent"] ||= []).first || ({ "locality" => [] })
        localities = extent["locality"] || []
        unless localities.any? { |l| l["type"] == "page" }
          localities << { "type" => "page", "reference_from" => match[:page].to_s }
          extent["locality"] = localities
          art["extent"] = [extent] unless art["extent"].any?
          changed = true
        end
      end
      # Add author(s) if none currently on the record.
      existing_authors = (art["contributor"] || []).any? do |c|
        c["role"]&.any? { |r| r["type"] == "author" }
      end
      if !existing_authors && match[:authors]&.any?
        art["contributor"] ||= []
        art["contributor"].concat(match[:authors].map do |name|
          { "role" => [{ "type" => "author" }],
            "person" => { "name" => { "completename" => { "content" => name } } } }
        end)
        changed = true
      end
      # Add pdf to provenance.
      ext = art["ext"] || {}
      prov = ext["provenance"] || []
      unless prov.include?("pdf")
        prov << "pdf"
        ext["provenance"] = prov
        art["ext"] = ext
        changed = true
      end
      changed
    end

    # Parse the Contents / SOMMAIRE section from the OCR'd text.
    def parse_contents(text)
      lines = text.lines.map { |l| l.rstrip }
      # pdftotext sometimes emits control chars (form feed, start-of-heading)
      # before the Contents heading — strip them before matching.
      start_idx = lines.index { |l| l.gsub(/[\x00-\x1f]/, "").strip.match?(/\A(Contents|SOMMAIRE)\z/i) }
      return [] unless start_idx

      entries = []
      current_section = nil
      i = start_idx + 1
      while i < lines.size
        line = lines[i].strip
        i += 1
        next if line.empty?

        # Section label
        if SECTION_LABELS.any? { |l| line.downcase == l.gsub('"', '') }
          current_section = line.downcase
          next
        end

        # Stop on the next major section / page break indicator.
        break if line.match?(/\A(EDITORIAL|PRESIDENT|MEMBER STATES|OIML BULLETIN)\z/i)

        # TOC entry: "<page> <title...>"
        m = line.match(/\A(\d+)\s+(.+)\z/)
        next unless m

        page = m[1].to_i
        title = m[2].strip
        authors = []
        # Continuation lines until next TOC entry, section label, or blank.
        while i < lines.size
          nxt = lines[i].strip
          break if nxt.empty?
          break if nxt.match?(/\A\d+\s+/)
          break if SECTION_LABELS.any? { |l| nxt.downcase == l.gsub('"', '') }
          break if nxt.match?(/\A(EDITORIAL|PRESIDENT|MEMBER STATES|OIML BULLETIN)\z/i)

          if author_line?(nxt)
            authors.concat(split_authors(nxt))
          else
            title = "#{title} #{nxt}".squeeze(" ")
          end
          i += 1
        end
        entries << { title: title.strip, authors: authors, page: page, section: current_section }
      end
      entries
    end

    def author_line?(line)
      return false unless line.match?(/\A[A-Z]/)
      return false if line.length > 120

      # Authors are typically 1-5 comma/and-separated names, each with
      # optional initials.
      cleaned = line.gsub(/\b(and|&)\b/i, ",")
      parts = cleaned.split(",").map(&:strip).reject(&:empty?)
      parts.all? { |p| p.match?(/\A[A-Z][A-Za-z.'-]+(?:\s+[A-Z][A-Za-z.'-]+){0,3}\z/) } && parts.size <= 6
    end

    def split_authors(line)
      line.gsub(/\b(and|&)\b/i, ",").split(",").map(&:strip).reject(&:empty?)
    end

    def titles_match?(a, b)
      na, nb = normalize(a), normalize(b)
      return true if na == nb
      return true if na.size > 20 && (na.include?(nb) || nb.include?(na))
      return true if na.size > 20 && nb.size > 20 && na[0, 40] == nb[0, 40]

      false
    end

    def normalize(s)
      s.to_s.downcase.gsub(/[àâäàá]/, "a").gsub(/[éèêë]/, "e").gsub(/[îï]/, "i")
       .gsub(/[ôö]/, "o").gsub(/[ûüù]/, "u").gsub(/[ç]/, "c")
       .gsub(/[^a-z0-9 ]/, "").squeeze(" ").strip
    end

    def write_yaml(path, hash)
      # Re-serialize through Relaton::Bib::Item so the result round-trips.
      item = Relaton::Bib::Item.from_hash(hash, {})
      File.write(path, item.to_yaml, encoding: "UTF-8")
    end
  end
end

if $PROGRAM_NAME == __FILE__
  root = File.expand_path("~/src/oimlsmart/bulletin-data")
  r = BulletinBackfill::EnrichFromPdfText.new(
    data_dir: File.expand_path("../data", __dir__),
    bulletin_data_root: root,
  ).run
  puts "Enrichment complete:"
  puts "  issues enriched: #{r.stats[:issues_enriched]}"
  puts "  articles patched: #{r.stats[:articles_enriched]}"
  puts "  issues with no parseable contents: #{r.stats[:issues_no_contents]}"
  puts "  issues with no data records: #{r.stats[:issues_no_data]}"
end
