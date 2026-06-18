# frozen_string_literal: true

require "yaml"

module OimlFetcher
  # Walks pdfs/*/parts_*/ to discover portfolio-extracted parts, parses their
  # filenames, and emits part-level Relaton YAMLs. Patches the parent series
  # YAML to add `hasPart` relations.
  #
  # Filename grammar (case-insensitive, original OIML casing preserved):
  #   <PREFIX><NUM>[-<PARTS>][-<SUFFIX>]-<LANG><YEAR>[-reconfirmed-<YEAR>].pdf
  #   PREFIX  = R|D|G|V|B|E|S
  #   NUM     = zero-padded number (035)
  #   PARTS   = part number, optionally combined (1 or 1-2)
  #   SUFFIX  = amend|amendment|annexes|ann-<X>|errata|erratum
  #   LANG    = e|f
  #   YEAR    = 2-digit (assume 20xx) or 4-digit
  class PartsBuilder
    SUFFIX_PATTERNS = {
      "amendment" => /[-_]amend(?:ment)?\z/i,
      "errata"    => /[-_]errat(?:um|a)\z/i,
      "annexes"   => /[-_]annexes\z/i,
      "annex"     => /[-_]ann(?:ex)?[-_]([a-z](?:[-_]?[a-z])*)\z/i,
    }.freeze

    attr_reader :parts, :amendments, :annexes, :errata

    def initialize(data_dir:, pdfs_dir:, yaml_store:)
      @data_dir = File.expand_path(data_dir)
      @pdfs_dir = File.expand_path(pdfs_dir)
      @yaml_store = yaml_store
      @parts = []
      @amendments = []
      @annexes = []
      @errata = []
    end

    def run
      discover
      emit_all
      patch_series
      say "Built #{@parts.length} parts, #{@amendments.length} amendments, " \
          "#{@annexes.length} annexes, #{@errata.length} errata"
    end

    private

    def discover
      Dir[File.join(@pdfs_dir, "*", "parts_*", "*.pdf")].sort.each do |path|
        entry = parse_part(path) || next
        categorize(entry)
      end
    end

    def parse_part(path)
      filename = File.basename(path)
      stem = filename.sub(/\.pdf\z/i, "")
      lang = File.basename(File.dirname(path)).sub(/\Aparts_/, "")

      parser = FilenameParser.new(stem)
      return nil unless parser.parse

      OpenStruct.new(
        filename: filename,
        path: path,
        lang: lang,
        prefix: parser.prefix,
        number: parser.number,
        parts: parser.parts,
        suffix: parser.suffix,
        annex_letter: parser.annex_letter,
        year: parser.year,
        reconfirmed: parser.reconfirmed,
        original_year: parser.original_year,
        series_dir: File.basename(File.dirname(File.dirname(path))),
      )
    rescue StandardError => e
      warn "  parse fail for #{filename}: #{e.message}"
      nil
    end

    def categorize(entry)
      case entry.suffix
      when nil
        @parts << entry if entry.parts
      when "amendment" then @amendments << entry
      when "annex", "annexes" then @annexes << entry
      when "errata" then @errata << entry
      end
    end

    # ---- YAML emission ----

    def emit_all
      group_and_emit(@parts) { |e| build_part_work(e) }
      group_and_emit(@amendments) { |e| build_amendment_work(e) }
      group_and_emit(@annexes) { |e| build_annex_work(e) }
      group_and_emit(@errata) { |e| build_errata_work(e) }
    end

    def group_and_emit(entries)
      by_docid = entries.group_by { |e| work_docid(e) }
      by_docid.each_value do |group|
        primary = group.first
        work_hash = yield primary
        next unless work_hash

        write_yaml(work_hash, work_filename(primary))
        group.each do |e|
          inst = build_instance(e)
          write_yaml(inst, instance_filename(e))
        end
      end
    end

    # ---- Builders ----

    def build_part_work(entry)
      docid = work_docid(entry)
      {
        "id" => id_from_docid(docid),
        "type" => "standard",
        "docidentifier" => [{ "content" => docid, "type" => "OIML", "primary" => true }],
        "docnumber" => entry.number.to_s,
        "title" => [{ "language" => "eng", "content" => "Part #{entry.parts.join('-')}", "type" => "main" }],
        "language" => %w[eng fra],
        "script" => ["Latn"],
        "date" => [{ "type" => "published", "from" => "#{entry.year}-01-01" }],
        "contributor" => [oiml_publisher],
        "status" => { "stage" => { "content" => "in-force" } },
        "relation" => [
          { "type" => "partOf", "bibitem" => bare_bibitem(series_docid(entry)) },
        ],
        "ext" => { "doctype" => { "content" => doctype_for(entry) }, "flavor" => "oiml" },
      }
    end

    def build_amendment_work(entry)
      docid = work_docid(entry)
      amends_docid = amends_target_docid(entry)
      {
        "id" => id_from_docid(docid),
        "type" => "standard",
        "docidentifier" => [{ "content" => docid, "type" => "OIML", "primary" => true }],
        "docnumber" => entry.number.to_s,
        "title" => [{ "language" => "eng", "content" => amendment_title(entry), "type" => "main" }],
        "language" => %w[eng fra],
        "script" => ["Latn"],
        "date" => [{ "type" => "published", "from" => "#{entry.year}-01-01" }],
        "contributor" => [oiml_publisher],
        "status" => { "stage" => { "content" => "in-force" } },
        "relation" => [
          { "type" => "amends", "bibitem" => bare_bibitem(amends_docid) },
        ],
        "ext" => { "doctype" => { "content" => doctype_for(entry) }, "flavor" => "oiml" },
      }
    end

    def build_annex_work(entry)
      docid = work_docid(entry)
      {
        "id" => id_from_docid(docid),
        "type" => "standard",
        "docidentifier" => [{ "content" => docid, "type" => "OIML", "primary" => true }],
        "docnumber" => entry.number.to_s,
        "title" => [{ "language" => "eng", "content" => annex_title(entry), "type" => "main" }],
        "language" => %w[eng fra],
        "script" => ["Latn"],
        "date" => [{ "type" => "published", "from" => "#{entry.year}-01-01" }],
        "contributor" => [oiml_publisher],
        "status" => { "stage" => { "content" => "in-force" } },
        "relation" => [
          { "type" => "partOf", "bibitem" => bare_bibitem(series_docid(entry)) },
        ],
        "ext" => { "doctype" => { "content" => doctype_for(entry) }, "flavor" => "oiml" },
      }
    end

    def build_errata_work(entry)
      docid = work_docid(entry)
      updates_docid = errata_target_docid(entry)
      {
        "id" => id_from_docid(docid),
        "type" => "standard",
        "docidentifier" => [{ "content" => docid, "type" => "OIML", "primary" => true }],
        "docnumber" => entry.number.to_s,
        "title" => [{ "language" => "eng", "content" => "Errata", "type" => "main" }],
        "language" => %w[eng fra],
        "script" => ["Latn"],
        "date" => [{ "type" => "published", "from" => "#{entry.year}-01-01" }],
        "contributor" => [oiml_publisher],
        "status" => { "stage" => { "content" => "in-force" } },
        "relation" => [
          { "type" => "updates", "bibitem" => bare_bibitem(updates_docid) },
        ],
        "ext" => { "doctype" => { "content" => doctype_for(entry) }, "flavor" => "oiml" },
      }
    end

    def build_instance(entry)
      work_docid = work_docid(entry)
      docid_suffix = OimlFetcher::DOCID_LANG_CODE.fetch(entry.lang)
      inst_docid = "#{work_docid} (#{docid_suffix})"
      rel_path = entry.path.sub(%r{^#{Regexp.escape(@pdfs_dir)}/}, "")

      {
        "id" => "#{id_from_docid(work_docid)}-#{entry.lang}",
        "type" => "standard",
        "docidentifier" => [{ "content" => inst_docid, "type" => "OIML", "primary" => true }],
        "docnumber" => entry.number.to_s,
        "source" => [OimlFetcher::Source.local("pdfs/#{rel_path}")],
        "language" => [entry.lang],
        "script" => ["Latn"],
        "date" => [{ "type" => "published", "from" => "#{entry.year}-01-01" }],
        "contributor" => [oiml_publisher],
        "status" => { "stage" => { "content" => "in-force" } },
        "relation" => [
          { "type" => "instanceOf", "bibitem" => bare_bibitem(work_docid) },
        ],
        "ext" => { "doctype" => { "content" => doctype_for(entry) }, "flavor" => "oiml" },
      }
    end

    # ---- Series patching ----

    def patch_series
      all_parts_by_series = @parts.group_by { |e| e.series_dir }
      all_annexes_by_series = @annexes.group_by { |e| e.series_dir }

      (all_parts_by_series.keys | all_annexes_by_series.keys).each do |series_dir|
        next unless @yaml_store.exist?(series_dir)

        parts = all_parts_by_series[series_dir] || []
        annexes = all_annexes_by_series[series_dir] || []
        patch_one_series(series_dir, parts, annexes)
      end
    end

    def patch_one_series(name, parts, annexes)
      @yaml_store.patch(name) do |data|
        data["relation"] ||= []

        (parts + annexes).each do |e|
          target = work_docid(e)
          next if data["relation"].any? { |r| r.dig("bibitem", "docidentifier", 0, "content") == target }

          data["relation"] << {
            "type" => "hasPart",
            "bibitem" => bare_bibitem(target),
          }
        end
        data
      end
    end

    # ---- Helpers ----

    def work_docid(entry)
      case entry.suffix
      when nil        then base_docid_with_parts(entry)
      when "amendment" then "#{base_docid_with_parts(entry, vintage_year: false)}:#{entry.year} Amendment"
      when "annexes"   then "#{base_docid(entry)}:#{entry.year} Annexes"
      when "annex"     then "#{base_docid(entry)}:#{entry.year} Annex #{entry.annex_letter}"
      when "errata"    then "#{base_docid_with_parts(entry, vintage_year: false)}:#{entry.year} Errata"
      end
    end

    def base_docid(entry)
      "OIML #{entry.prefix} #{entry.number}"
    end

    def base_docid_with_parts(entry, vintage_year: true)
      core = if entry.parts
               "#{entry.prefix} #{entry.number}-#{entry.parts.join('-')}"
             else
               "#{entry.prefix} #{entry.number}"
             end
      vintage_year ? "OIML #{core}:#{entry.year}" : "OIML #{core}"
    end

    def series_docid(entry)
      return base_docid(entry) unless entry.series_dir =~ /\A([a-z])(\d+(?:-\d+)*)_(\d{4})\z/

      "OIML #{$1.upcase} #{$2}:#{$3}"
    end

    def amends_target_docid(entry)
      core = if entry.parts
               "#{entry.prefix} #{entry.number}-#{entry.parts.join('-')}"
             else
               "#{entry.prefix} #{entry.number}"
             end
      target_year = entry.original_year || series_year(entry.series_dir)
      "OIML #{core}:#{target_year}"
    end

    alias_method :errata_target_docid, :amends_target_docid

    def series_year(series_dir)
      return nil unless series_dir =~ /_(\d{4})\z/

      Regexp.last_match(1).to_i
    end

    def amendment_title(entry)
      "Amendment #{entry.year}"
    end

    def annex_title(entry)
      entry.suffix == "annexes" ? "Annexes" : "Annex #{entry.annex_letter}"
    end

    def doctype_for(entry)
      case entry.prefix
      when "R" then "recommendation"
      when "D" then "document"
      when "G" then "guide"
      when "V" then "vocabulary"
      when "B" then "basic-publication"
      when "E" then "expert-report"
      when "S" then "seminar-report"
      end
    end

    def id_from_docid(docid)
      docid.sub(/\AOIML\s+/, "").gsub(/\s+/, "").tr(":", "-")
    end

    def bare_bibitem(docid)
      { "docidentifier" => [{ "content" => docid, "type" => "OIML" }] }
    end

    def oiml_publisher
      {
        "role" => [{ "type" => "publisher" }],
        "organization" => {
          "name" => [{ "content" => OimlFetcher::OIML_NAME }],
          "abbreviation" => { "content" => OimlFetcher::OIML_ABBR },
        },
      }
    end

    def work_filename(entry)
      "#{id_from_docid(work_docid(entry)).downcase}.yaml"
    end

    def instance_filename(entry)
      "#{id_from_docid(work_docid(entry)).downcase}_#{entry.lang}.yaml"
    end

    def write_yaml(hash, name)
      @yaml_store.write(name, hash, overwrite: false)
    rescue StandardError => e
      warn "  emit fail for #{name}: #{e.message}"
    end

    def say(msg)
      $stdout.puts msg
    end

    # Lightweight struct since Ruby 3.x has Data but OpenStruct works fine.
    OpenStruct = Struct.new(:filename, :path, :lang, :prefix, :number, :parts,
                            :suffix, :annex_letter, :year, :reconfirmed,
                            :original_year, :series_dir,
                            keyword_init: true)

    # Parser for a single filename stem (no extension, no language prefix).
    class FilenameParser
      attr_reader :prefix, :number, :parts, :suffix, :annex_letter, :year,
                  :reconfirmed, :original_year

      def initialize(stem)
        @stem = stem
      end

      def parse
        s = @stem

        if (m = /-reconfirmed-(\d{4})\z/i.match(s))
          @reconfirmed = m[1].to_i
          s = m.pre_match
        end

        if (m = /-([ef])(\d{2}|\d{4})\z/i.match(s))
          @lang_char = m[1].downcase
          @year = normalize_year(m[2])
          s = m.pre_match
        elsif (m = /-(\d{4})-(\d{2})-(\d{2})\z/.match(s))
          @year = m[1].to_i
          s = m.pre_match
        else
          return false
        end

        SUFFIX_PATTERNS.each do |type, regex|
          if (mm = regex.match(s))
            @suffix = type
            @annex_letter = mm[1].upcase if type == "annex"
            s = mm.pre_match
            break
          end
        end

        if (m = /-([ef])(\d{2}|\d{4})\z/i.match(s))
          @original_year = normalize_year(m[2])
          s = m.pre_match
        end

        if (m = /\A([rdgvbs])(\d+)(?:-(\d+(?:-\d+)?))?\z/i.match(s))
          @prefix = m[1].upcase
          @number = m[2].to_i
          @parts = m[3]&.split("-")&.map(&:to_i)
          true
        else
          false
        end
      end

      def normalize_year(y)
        n = y.to_i
        n < 100 ? (n < 50 ? 2000 + n : 1900 + n) : n
      end
    end
  end
end
