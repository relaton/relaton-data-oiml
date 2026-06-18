# frozen_string_literal: true

module OimlFetcher
  # Immutable value object representing an OIML document identifier across
  # all its forms: short_title from the JSON API ("R 35:2007(en)"), ref from
  # translation HTML ("R 35-1:2007"), and PDF filename ("R035-1-e07.pdf").
  #
  # Three constructors normalise the input grammars; accessors expose the
  # parsed fields; derived forms produce every shape downstream code needs
  # (id, filename stem, docid string, language-suffixed docid, etc.).
  class Docid
    SUFFIX_TYPES = %i[amendment annex annexes errata].freeze

    attr_reader :prefix, :number, :parts, :year, :original_year,
                :lang, :suffix_type, :annex_letter, :reconfirmed_year

    def initialize(prefix:, number:, parts: nil, year: nil, original_year: nil,
                   lang: nil, suffix_type: nil, annex_letter: nil,
                   reconfirmed_year: nil)
      @prefix = prefix
      @number = number
      @parts = parts && parts.dup.freeze
      @year = year
      @original_year = original_year
      @lang = lang
      @suffix_type = suffix_type
      @annex_letter = annex_letter
      @reconfirmed_year = reconfirmed_year
      freeze
    end

    # --- Constructors (one per input grammar) ---

    def self.from_short_title(short_title)
      core = strip_locale_parens(short_title)
      core = strip_locale_suffix(core)
      core = strip_oiml_prefix(core)
      parse_core(core)
    end

    def self.from_translation_ref(ref)
      parse_core(ref)
    end

    def self.from_pdf_filename(filename)
      stem = filename.sub(/\.pdf\z/i, "")
      PdfFilenameParser.parse(stem)
    end

    # --- Derived forms ---

    def to_s
      "OIML #{core_with_year}"
    end

    def id
      slug.sub(/^-+|-+$/, "")
    end

    def filename_stem
      id.downcase
    end

    def with_lang(lang_code)
      suffix = OimlFetcher::DOCID_LANG_CODE.fetch(lang_code)
      "#{to_s} (#{suffix})"
    end

    def with_suffix(new_suffix_type, year: nil, annex_letter: nil)
      self.class.new(
        prefix: prefix, number: number, parts: parts,
        year: year || self.year,
        original_year: original_year,
        lang: lang, suffix_type: new_suffix_type,
        annex_letter: annex_letter,
        reconfirmed_year: reconfirmed_year,
      )
    end

    def relation_target
      to_s
    end

    def core_string
      parts_core
    end

    def ==(other)
      other.is_a?(Docid) && other.to_s == to_s && other.lang == lang &&
        other.suffix_type == suffix_type && other.annex_letter == annex_letter
    end

    private

    def core_with_year
      return apply_suffix(parts_core) unless year

      apply_suffix("#{parts_core}:#{year}")
    end

    def parts_core
      b = "#{prefix} #{number}"
      b += "-#{parts.join('-')}" if parts
      b
    end

    def apply_suffix(base)
      case suffix_type
      when :amendment then "#{base} Amendment"
      when :annexes   then "#{base} Annexes"
      when :annex     then "#{base} Annex #{annex_letter}"
      when :errata    then "#{base} Errata"
      else base
      end
    end

    def slug
      core_with_year
        .sub(/\AOIML\s+/, "")
        .gsub(/\s+/, "")
        .tr(":", "-")
        .gsub(/[^A-Za-z0-9-]/, "")
    end

    class << self
      private

      def strip_locale_parens(str)
        m = /^(.+?)\s*\((?:en|fr|E|F)\)\s*\z/i.match(str)
        m ? m[1] : str
      end

      def strip_locale_suffix(str)
        str.sub(/-en\z/i, "").sub(/-fr\z/i, "")
      end

      def strip_oiml_prefix(str)
        str.sub(/\AOIML\s+/i, "")
      end

      # rubocop:disable Metrics/MethodLength
      def parse_core(str)
        m = /\A([A-Z])\s*(\d+)(?:-(\d+(?:-\d+)?))?(?::(\d{4}))?\z/.match(str)
        raise ArgumentError, "Unrecognized docid format: #{str.inspect}" unless m

        prefix = m[1]
        number = m[2].to_i
        parts = m[3] && m[3].split("-").map(&:to_i)
        year = m[4] && m[4].to_i
        new(prefix: prefix, number: number, parts: parts, year: year)
      end
      # rubocop:enable Metrics/MethodLength
    end

    # Inner parser that understands the PDF filename grammar. Used by
    # +from_pdf_filename+. Lives here so that +Docid+ remains the single
    # entry point for all docid-related parsing.
    class PdfFilenameParser
      SUFFIX_PATTERNS = {
        amendment: /[-_]amend(?:ment)?\z/i,
        errata:    /[-_]errat(?:um|a)\z/i,
        annexes:   /[-_]annexes\z/i,
        annex:     /[-_]ann(?:ex)?[-_]([a-z](?:[-_]?[a-z])*)\z/i,
      }.freeze

      attr_reader :prefix, :number, :parts, :year, :original_year,
                  :lang, :suffix_type, :annex_letter, :reconfirmed_year

      def self.parse(stem)
        new(stem).parse
      end

      def initialize(stem)
        @stem = stem
      end

      def parse
        s = @stem

        strip_reconfirmed(s) { |rest, year| @reconfirmed_year = year; s = rest }
        strip_year_and_lang(s) do |rest, lang, year|
          @lang = lang
          @year = year
          s = rest
        end or return nil
        strip_suffix(s) do |rest, type, letter|
          @suffix_type = type
          @annex_letter = letter if type == :annex
          s = rest
        end
        strip_original_year(s) { |rest, year| @original_year = year; s = rest }
        parse_base(s) or return nil

        Docid.new(
          prefix: @prefix, number: @number, parts: @parts, year: @year,
          original_year: @original_year, lang: @lang,
          suffix_type: @suffix_type, annex_letter: @annex_letter,
          reconfirmed_year: @reconfirmed_year,
        )
      end

      private

      def strip_reconfirmed(s)
        m = /-reconfirmed-(\d{4})\z/i.match(s)
        return unless m

        yield m.pre_match, m[1].to_i
      end

      def strip_year_and_lang(s)
        m = /-([ef])(\d{2}|\d{4})\z/i.match(s)
        if m
          yield m.pre_match, lang_for(m[1]), normalize_year(m[2])
          return true
        end
        m = /-(\d{4})-(\d{2})-(\d{2})\z/.match(s)
        return false unless m

        yield m.pre_match, nil, m[1].to_i
        true
      end

      def strip_suffix(s)
        SUFFIX_PATTERNS.each do |type, regex|
          mm = regex.match(s)
          next unless mm

          letter = type == :annex ? mm[1].upcase : nil
          yield mm.pre_match, type, letter
          return
        end
      end

      def strip_original_year(s)
        m = /-([ef])(\d{2}|\d{4})\z/i.match(s)
        return unless m

        yield m.pre_match, normalize_year(m[2])
      end

      def parse_base(s)
        m = /\A([rdgvbs])(\d+)(?:-(\d+(?:-\d+)?))?\z/i.match(s)
        return false unless m

        @prefix = m[1].upcase
        @number = m[2].to_i
        @parts = m[3] && m[3].split("-").map(&:to_i)
        true
      end

      def lang_for(char)
        char.downcase == "e" ? "eng" : "fra"
      end

      def normalize_year(y)
        n = y.to_i
        n < 100 ? (n < 50 ? 2000 + n : 1900 + n) : n
      end
    end
    private_constant :PdfFilenameParser
  end
end
