# frozen_string_literal: true

require "json"
require "set"

module OimlFetcher
  # Builds part-level YAMLs from cover-page PDFs whose /Link annotations
  # point to per-part PDFs (e.g. r049-e24.pdf → r049-1-e24.pdf … r049-4-e24.pdf).
  #
  # Reads sidecar `parts_<lang>/links.json` files written by PortfolioFetcher.
  # Patches the parent series YAML with `hasPart` relations.
  class CoverPageBuilder
    # Match a part PDF URL like .../pdf_r/r049-1-e24.pdf
    URI_PART_RE = %r{/pdf_([a-z])/[a-z]?(\d{3})-(\d+)-([ef])(\d{2,4})}i.freeze

    DOCTYPE_BY_PREFIX = {
      "R" => "recommendation",
      "D" => "document",
      "G" => "guide",
      "V" => "vocabulary",
      "B" => "basic-publication",
      "E" => "expert-report",
      "S" => "seminar-report",
    }.freeze

    LANG_BY_CHAR = { "e" => "eng", "f" => "fra" }.freeze

    def initialize(data_dir:, pdfs_dir:, yaml_store:)
      @data_dir = File.expand_path(data_dir)
      @pdfs_dir = File.expand_path(pdfs_dir)
      @yaml_store = yaml_store
    end

    def run
      stats = { parts: 0, parents: 0 }
      Dir[File.join(@pdfs_dir, "*", "parts_*", "links.json")].sort.each do |links_path|
        next if File.size(links_path).zero?

        series_dir = File.basename(File.dirname(File.dirname(links_path)))
        parent_stem = parent_stem_for(series_dir)
        next unless parent_stem

        parent_docid = read_parent_docid(parent_stem)
        next unless parent_docid

        seen_on_parent = Set.new(parent_has_part_docids(parent_stem))
        uris = JSON.parse(File.read(links_path)).map { |e| e["uri"] }
        emitted_any = false
        uris.each do |uri|
          parsed = parse_link(uri)
          next unless parsed

          prefix, number, part_num, lang_char, year = parsed.values_at(:prefix, :number, :part, :lang_char, :year)
          work_docid = "OIML #{prefix} #{number}-#{part_num}:#{year}"
          part_stem = "#{prefix.downcase}#{number}-#{part_num}-#{year}"

          emit_part_work(part_stem, prefix, number, part_num, year, work_docid, parent_docid)
          emit_part_instance(part_stem, prefix, number, part_num, year, work_docid, lang_char, uri)
          stats[:parts] += 1
          emitted_any = true
          next if seen_on_parent.include?(work_docid)

          add_parent_has_part(parent_stem, work_docid)
          seen_on_parent << work_docid
        end
        stats[:parents] += 1 if emitted_any
      end
      say "CoverPageBuilder: emitted #{stats[:parts]} parts across #{stats[:parents]} parents"
    end

    private

    def parse_link(uri)
      m = URI_PART_RE.match(uri)
      return nil unless m

      {
        prefix: m[1].upcase,
        number: m[2].to_i,
        part: m[3].to_i,
        lang_char: m[4].downcase,
        year: normalize_year(m[5]),
      }
    end

    def normalize_year(y)
      n = y.to_i
      n < 100 ? (n < 50 ? 2000 + n : 1900 + n) : n
    end

    def parent_stem_for(series_dir)
      stem = series_dir.sub(/_(eng|fra|deu|ara|zho|fas|pol|por|rus|srp|spa|ukr)\z/, "")
      @yaml_store.exist?(stem) ? stem : nil
    end

    def read_parent_docid(parent_stem)
      data = @yaml_store.read(parent_stem)
      data["docidentifier"].find { |d| d["type"] == "OIML" && d["primary"] }&.dig("content")
    rescue StandardError
      nil
    end

    def parent_has_part_docids(parent_stem)
      data = @yaml_store.read(parent_stem)
      Array(data["relation"]).select { |r| r["type"] == "hasPart" }
        .map { |r| r.dig("bibitem", "docidentifier", 0, "content") }
    rescue StandardError
      []
    end

    def add_parent_has_part(parent_stem, part_docid)
      @yaml_store.patch(parent_stem) do |data|
        data["relation"] ||= []
        data["relation"] << {
          "type" => "hasPart",
          "bibitem" => { "docidentifier" => [{ "content" => part_docid, "type" => "OIML" }] },
        }
        data
      end
    end

    def emit_part_work(part_stem, prefix, number, part_num, year, work_docid, parent_docid)
      return if @yaml_store.exist?(part_stem)

      hash = {
        "id" => "#{prefix}#{number}-#{part_num}-#{year}",
        "type" => "standard",
        "title" => [{ "language" => "eng", "content" => "Part #{part_num}", "type" => "main" }],
        "docidentifier" => [{ "content" => work_docid, "type" => "OIML", "primary" => true }],
        "docnumber" => number.to_s,
        "date" => [{ "type" => "published", "from" => "#{year}-01-01" }],
        "contributor" => [OimlFetcher.oiml_publisher_contributor],
        "language" => %w[eng fra],
        "script" => ["Latn"],
        "status" => { "stage" => { "content" => "in-force" } },
        "relation" => [{
          "type" => "partOf",
          "bibitem" => { "docidentifier" => [{ "content" => parent_docid, "type" => "OIML" }] },
        }],
        "ext" => { "doctype" => { "content" => DOCTYPE_BY_PREFIX.fetch(prefix, "recommendation") }, "flavor" => "oiml" },
      }
      @yaml_store.write(part_stem, hash)
    end

    def emit_part_instance(part_stem, prefix, number, part_num, year, work_docid, lang_char, uri)
      lang_full = LANG_BY_CHAR.fetch(lang_char, "eng")
      inst_stem = "#{part_stem}_#{lang_full}"
      return if @yaml_store.exist?(inst_stem)

      suffix = OimlFetcher::DOCID_LANG_CODE.fetch(lang_full)
      hash = {
        "id" => "#{prefix}#{number}-#{part_num}-#{year}-#{lang_full}",
        "type" => "standard",
        "source" => [OimlFetcher::Source.url(uri.sub(/#.*\z/, ""))],
        "docidentifier" => [{ "content" => "#{work_docid} (#{suffix})", "type" => "OIML", "primary" => true }],
        "docnumber" => number.to_s,
        "date" => [{ "type" => "published", "from" => "#{year}-01-01" }],
        "contributor" => [OimlFetcher.oiml_publisher_contributor],
        "language" => [lang_full],
        "script" => ["Latn"],
        "status" => { "stage" => { "content" => "in-force" } },
        "relation" => [{
          "type" => "instanceOf",
          "bibitem" => { "docidentifier" => [{ "content" => work_docid, "type" => "OIML" }] },
        }],
        "ext" => { "doctype" => { "content" => DOCTYPE_BY_PREFIX.fetch(prefix, "recommendation") }, "flavor" => "oiml" },
      }
      @yaml_store.write(inst_stem, hash)
    end

    def say(msg)
      $stdout.puts msg
    end
  end
end
