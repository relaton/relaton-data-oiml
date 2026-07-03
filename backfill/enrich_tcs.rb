# frozen_string_literal: true

# One-off: backfill TC/SC committee data into data/*.yaml for every
# OIML publication that lacks it. Idempotent — only patches YAMLs that
# have no author/committee contributor.
#
# Two data sources, in priority order:
#
#   1. oiml.org JSON API (all doctypes: R, D, G, V, B, E, S)
#      /en/publications/<type>/@@API/publications?id_type=<N>&id_status=<S>
#      Each entry's `scTitle` carries the authoring body
#      (e.g. "TC9/SC2", "BIML", "BIML/SC3", "CEEMS").
#
#   2. oiml.caco3consulting.com (Recommendations only — used as fallback
#      when oiml.org has no scTitle for a given R entry, typically older
#      superseded/withdrawn issues).
#      /recommendation/<N>/<YEAR>/ — "Developed by" link exposes the TC.
#
# Run:
#   bundle exec ruby backfill/enrich_tcs.rb

$LOAD_PATH.unshift(File.expand_path("../lib", __dir__))
require "oiml_fetcher"
require "nokogiri"
require "json"
require "fileutils"

module Backfill
  class EnrichTcs
    CACO3_BASE = "https://oiml.caco3consulting.com".freeze
    CACHE_DIR = File.expand_path("cache/tc_enrichment", __dir__)
    USER_AGENT = "relaton-data-oiml/tc-enrich".freeze

    # Parse fields from the docidentifier.content in a YAML file.
    # Handles all OIML identifier shapes:
    #   OIML R 35:2007           (work)
    #   OIML R 35-1:2007 (E)     (instance with part + lang)
    #   OIML R 60-sup:2000       (supplement)
    #   OIML R 10 Amendment:2024 (amendment)
    #   OIML R 126-erratum:2012  (erratum)
    #   OIML R 102 AnnexB-C:1995 (annex)
    # Strategy: extract prefix+number from the head, year from the tail
    # (after colon), and treat the middle as either parts ("-2", "-2-3")
    # or a suffix to discard ("-sup", "Amendment", "AnnexB-C").
    DOCID_HEAD = /\A([A-Z])\s*(\d+)/i.freeze
    DOCID_YEAR_TAIL = /:(\d{4})\z/.freeze
    PARTS_MIDDLE = /\A-?\d+(?:-\d+)*\z/.freeze
    LANG_PARENS = /\s*\([A-Za-z]{1,2}\)\s*\z/.freeze

    def initialize(data_dir:, yaml_store:, http: OimlFetcher::Http.backend, caco3: true)
      @data_dir = data_dir
      @yaml_store = yaml_store
      @http = http
      @use_caco3 = caco3
      @stats = Hash.new(0)
      @tc_map = {}
    end

    def run
      FileUtils.mkdir_p(CACHE_DIR)
      say "Phase A: fetching oiml.org JSON API..."
      build_tc_map_from_oiml_org
      say "  tc_map has #{@tc_map.size} entries"

      if @use_caco3
        say "Phase B: fetching caco3consulting.com for R gaps..."
        build_tc_map_from_caco3
        say "  tc_map has #{@tc_map.size} entries (after caco3)"
      end

      say "Phase C: walking data/*.yaml and patching..."
      walk_and_patch

      say "Done. Stats:"
      say "  oiml_org_entries_with_scTitle:  #{@stats[:oiml_with_sc]}"
      say "  caco3_pages_fetched:            #{@stats[:caco3_fetched]}"
      say "  caco3_tc_added:                 #{@stats[:caco3_added]}"
      say "  yaml_files_seen:                #{@stats[:yaml_seen]}"
      say "  yaml_skipped_already_has_tc:    #{@stats[:yaml_has_tc]}"
      say "  yaml_skipped_bulletin:          #{@stats[:yaml_bulletin]}"
      say "  yaml_skipped_unparseable_docid: #{@stats[:yaml_bad_docid]}"
      say "  yaml_no_tc_known:               #{@stats[:yaml_no_tc]}"
      say "  yaml_patched:                   #{@stats[:yaml_patched]}"
    end

    private

    # ============================================================
    # Phase A: oiml.org JSON API
    # ============================================================

    def build_tc_map_from_oiml_org
      OimlFetcher::TYPES.each do |segment, (p_type, _prefix, fr_segment, _)|
        OimlFetcher::ALL_STATUSES.each do |status|
          %w[en fr].each do |lang|
            url_seg = lang == "fr" ? fr_segment : segment
            url = "#{OimlFetcher::BASE_URL}/#{lang}/publications/#{url_seg}/" \
                  "@@API/publications?id_type=#{p_type}&id_status=#{status}"
            pubs = fetch_publications(url)
            next unless pubs

            pubs.each do |pub|
              sc = pub["scTitle"].to_s.strip
              next if sc.empty?

              @stats[:oiml_with_sc] += 1
              key = docid_key_from_short(pub["shortTitle"] || pub["ref"])
              next unless key

              @tc_map[key] ||= sc
            end
          rescue StandardError => e
            warn "  Skipping #{segment}/#{lang}/status=#{status}: #{e.message}"
          end
        end
      end
    end

    def fetch_publications(url)
      body = cache_fetch(url) { @http.get(url, headers: { "Accept" => "application/json", "User-Agent" => USER_AGENT }) }
      JSON.parse(body).fetch("publications", [])
    rescue JSON::ParserError, OimlFetcher::Http::Error => e
      warn "  HTTP/JSON error for #{url}: #{e.message}"
      nil
    end

    # ============================================================
    # Phase B: caco3consulting.com (Recommendations only)
    # ============================================================

    def build_tc_map_from_caco3
      numbers = caco3_recommendation_numbers
      say "  caco3 lists #{numbers.size} recommendation numbers"
      numbers.each do |number|
        years = caco3_edition_years(number)
        years.each do |year|
          @stats[:caco3_fetched] += 1
          tc = caco3_tc_for(number, year)
          next unless tc

          @stats[:caco3_added] += 1
          # Store under every plausible docid shape for that (number, year):
          #   R <N>:<YEAR>            (parent work)
          #   R <N>-<part>:<YEAR>     (each part, if any)
          store_caco3_tc(number, year, tc)
        rescue OimlFetcher::Http::BadStatus, OimlFetcher::Http::Error => e
          warn "  caco3 error R #{number}/#{year}: #{e.message}"
        end
      end
    end

    def caco3_recommendation_numbers
      html = caco3_get("#{CACO3_BASE}/recommendations/")
      doc = Nokogiri::HTML(html)
      doc.css("a[href*='/recommendation/']").map do |a|
        a["href"][%r{/recommendation/(\d+)/\z}, 1]
      end.compact.uniq.sort
    end

    def caco3_edition_years(number)
      html = caco3_get("#{CACO3_BASE}/recommendation/#{number}/")
      doc = Nokogiri::HTML(html)
      doc.css("a[href*=\"/recommendation/#{number}/\"]").map do |a|
        a["href"][%r{/recommendation/#{number}/(\d{4})/\z}, 1]
      end.compact.uniq.sort
    end

    def caco3_tc_for(number, year)
      html = caco3_get("#{CACO3_BASE}/recommendation/#{number}/#{year}/")
      doc = Nokogiri::HTML(html)
      node = doc.at_css("p:contains('Developed by')")
      return nil unless node

      link = node.at_css("a")
      return nil unless link

      tc = link.text.strip
      tc.empty? ? nil : tc
    end

    def store_caco3_tc(number, year, tc)
      parts = caco3_parts_for(number, year)
      # Parent work key (no parts)
      parent_key = docid_key("R", number, nil, year)
      @tc_map[parent_key] ||= tc
      # Per-part keys
      parts.each do |part_num|
        key = docid_key("R", number, [part_num], year)
        @tc_map[key] ||= tc
      end
    end

    def caco3_parts_for(number, year)
      # Re-use the cached edition page if available
      html = caco3_get("#{CACO3_BASE}/recommendation/#{number}/#{year}/")
      doc = Nokogiri::HTML(html)
      doc.css("a[href*=\"/recommendation/#{number}/#{year}/\"]").map do |a|
        a["href"][%r{/recommendation/#{number}/#{year}/(\d+)/\z}, 1]
      end.compact.uniq.map(&:to_i)
    end

    def caco3_get(url)
      cache_fetch(url) { @http.get(url, headers: { "Accept" => "text/html", "User-Agent" => USER_AGENT }) }
    end

    # ============================================================
    # Phase C: walk YAMLs and patch
    # ============================================================

    def walk_and_patch
      @yaml_store.each_yaml do |name, _path|
        @stats[:yaml_seen] += 1
        next if name.start_with?("bulletin_")
        next if name.start_with?("bulletin")

        @yaml_store.patch(name) do |hash|
          patch_hash(name, hash)
        end
      end
    end

    def patch_hash(_name, hash)
      return :skipped unless hash.is_a?(Hash)

      if has_committee?(hash)
        @stats[:yaml_has_tc] += 1
        return :skipped
      end

      fields = parse_docid_fields(hash)
      unless fields
        @stats[:yaml_bad_docid] += 1
        return :skipped
      end

      # Try exact key first, then parent (strip parts), then prefix-only (no year)
      tc = lookup_tc(fields)
      unless tc
        @stats[:yaml_no_tc] += 1
        return :skipped
      end

      add_committee_contributor!(hash, tc)
      @stats[:yaml_patched] += 1
      :patched
    end

    def has_committee?(hash)
      Array(hash["contributor"]).any? do |c|
        roles = Array(c["role"])
        roles.any? { |r| r["type"] == "author" } ||
          roles.any? { |r| Array(r["description"]).any? { |d| d["content"] == "committee" } }
      end
    end

    def lookup_tc(fields)
      # Tier 1: Exact match — OIML R 100-1:2013
      key = docid_key(fields[:prefix], fields[:number], fields[:parts], fields[:year])
      return @tc_map[key] if @tc_map.key?(key)

      # Tier 2: Same parts, any year — OIML R 100-1:<any>
      if fields[:parts]
        parts_suffix = "-#{fields[:parts].join('-')}"
        candidates = year_sorted_candidates("#{fields[:prefix]}-#{fields[:number]}#{parts_suffix}-")
        return candidates.first[1] if candidates.any?
      end

      # Tier 3: Drop parts, same year — OIML R 100:2013 (parent work)
      if fields[:parts] && fields[:year]
        parent = docid_key(fields[:prefix], fields[:number], nil, fields[:year])
        return @tc_map[parent] if @tc_map.key?(parent)
      end

      # Tier 4: Drop parts and year — any edition of the parent work
      # (e.g. R 35-2:2011 inherits from R 35:2007 because same committee owns the series)
      if fields[:parts]
        candidates = year_sorted_candidates("#{fields[:prefix]}-#{fields[:number]}-")
        # Pick the closest year ≤ target year if available, else most recent
        prior = candidates.find { |y, _| y <= (fields[:year] || Float::INFINITY) }
        return (prior || candidates.first)[1] if candidates.any?
      end

      # Tier 5: Same number, any year (no parts in either)
      unless fields[:parts]
        candidates = year_sorted_candidates("#{fields[:prefix]}-#{fields[:number]}-")
        prior = candidates.find { |y, _| y <= (fields[:year] || Float::INFINITY) }
        return (prior || candidates.first)[1] if candidates.any?
      end

      nil
    end

    def year_sorted_candidates(prefix)
      @tc_map.keys.select { |k| k.start_with?(prefix) }
        .map { |k| [k.split("-").last.to_i, @tc_map[k]] }
        .sort_by { |y, _| -y }
    end

    def add_committee_contributor!(hash, sc_title)
      hash["contributor"] ||= []
      hash["contributor"] << {
        "role" => [{ "type" => "author", "description" => [{ "content" => "committee" }] }],
        "organization" => {
          "name" => [{ "content" => OimlFetcher::OIML_NAME }],
          "subdivision" => subdivisions_for(sc_title),
          "abbreviation" => { "content" => OimlFetcher::OIML_ABBR },
        },
      }
    end

    # ============================================================
    # Docid parsing helpers
    # ============================================================

    # Parse fields from a shortTitle/ref string ("R 100-1:2013(en)" etc.)
    def docid_key_from_short(str)
      return nil unless str && !str.empty?

      cleaned = str.sub(/\AOIML\s+/i, "").gsub(LANG_PARENS, "")
      m = /\A([A-Z])\s*(\d+)(?:-(\d+(?:-\d+)?))?(?::(\d{4}))?\z/.match(cleaned)
      return nil unless m

      prefix = m[1]
      number = m[2].to_i
      parts = m[3] && m[3].split("-").map(&:to_i)
      year = m[4] && m[4].to_i
      docid_key(prefix, number, parts, year)
    rescue StandardError
      nil
    end

    def parse_docid_fields(hash)
      docids = Array(hash["docidentifier"])
      oiml = docids.find { |d| d["type"] == "OIML" } || docids.first
      return nil unless oiml

      str = oiml["content"].to_s
      str = str.sub(LANG_PARENS, "")
      str = str.sub(/\AOIML\s+/i, "")

      head = DOCID_HEAD.match(str)
      return nil unless head

      prefix = head[1].upcase
      number = head[2].to_i
      rest = head.post_match

      year = nil
      if (ym = DOCID_YEAR_TAIL.match(rest))
        year = ym[1].to_i
        rest = ym.pre_match
      end

      rest = rest.strip
      parts = nil
      if !rest.empty? && rest.match?(PARTS_MIDDLE)
        parts = rest.sub(/\A-/, "").split("-").map(&:to_i)
      end

      { prefix: prefix, number: number, parts: parts, year: year }
    rescue StandardError
      nil
    end

    def docid_key(prefix, number, parts, year)
      parts_suffix = parts ? "-#{parts.join('-')}" : ""
      year_suffix = year ? "-#{year}" : ""
      "#{prefix}-#{number}#{parts_suffix}#{year_suffix}"
    end

    # ============================================================
    # Subdivision builder (mirrors PublicationFetcher#subdivision_for
    # in lib/oiml_fetcher/publication_fetcher.rb — kept here as a
    # local copy so the backfill script is self-contained).
    # ============================================================

    def subdivisions_for(sc_title)
      sc_title.to_s.split("/").map { |code| subdivision_for(code) }
    end

    def subdivision_for(code)
      if (m = /^TC(\d+)$/.match(code))
        {
          "name" => [{ "content" => "Technical Committee #{m[1]}" }],
          "identifier" => [{ "content" => code }],
          "type" => "technical-committee",
        }
      elsif (m = /^SC(\d+)$/.match(code))
        {
          "name" => [{ "content" => "Subcommittee #{m[1]}" }],
          "identifier" => [{ "content" => code }],
          "type" => "subcommittee",
        }
      else
        {
          "name" => [{ "content" => code }],
          "identifier" => [{ "content" => code }],
          "type" => "technical-committee",
        }
      end
    end

    # ============================================================
    # Cache + IO
    # ============================================================

    def cache_fetch(url)
      digest = Digest::MD5.hexdigest(url)
      path = File.join(CACHE_DIR, "#{digest}.txt")
      return File.read(path) if File.exist?(path)

      body = yield
      File.write(path, body)
      body
    end

    def say(msg)
      $stdout.puts msg
    end
  end
end

require "digest"

Backfill::EnrichTcs.new(
  data_dir: File.expand_path("../data", __dir__),
  yaml_store: OimlFetcher::YamlStore.new(File.expand_path("../data", __dir__)),
).run
