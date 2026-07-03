# frozen_string_literal: true

require "nokogiri"

module OimlFetcher
  # Scrapes the demo site at oiml.caco3consulting.com for enriched
  # Recommendation metadata (scope, quantity, measuring instrument, focus
  # area, sustainability framework, DOI, part titles) and patches existing
  # data/r{N}_{year}*.yaml files.
  #
  # Only covers Recommendations (R prefix). Other publication types are not
  # on caco3.
  #
  # Non-standard relaton fields go under ext:
  #   ext:
  #     scope: "..."
  #     quantity: Mass
  #     measuring_instrument: Automatic weighing instrument
  #     focus_area: Trade
  #     sustainability_framework: Prosperity
  #     doi: 10.63493/r150.2020.en
  class Caco3Fetcher
    BASE_URL = "https://oiml.caco3consulting.com".freeze

    def initialize(data_dir:, yaml_store:, http: OimlFetcher::Http)
      @data_dir = File.expand_path(data_dir)
      @yaml_store = yaml_store
      @http = http
    end

    def run
      numbers = recommendation_numbers
      say "Found #{numbers.length} recommendations on caco3"
      numbers.each do |number|
        enrich_recommendation(number)
      rescue StandardError => e
        warn "  ERROR enriching R #{number}: #{e.message}"
      end
      say "Done."
    end

    private

    def recommendation_numbers
      html = fetch_html("#{BASE_URL}/recommendations/")
      doc = Nokogiri::HTML(html)
      doc.css("div.card a[href*='/recommendation/']").map do |a|
        a["href"][%r{/recommendation/(\d+)/}, 1]
      end.compact.uniq.sort
    end

    def enrich_recommendation(number)
      editions = fetch_editions(number)
      general = fetch_general_metadata(number)
      editions.each do |year|
        edition_data = fetch_edition_page(number, year)
        next unless edition_data

        parent_stem = "r#{number}_#{year}"
        unless @yaml_store.exist?(parent_stem)
          ensure_parent_work_yaml(number, year, edition_data.merge(general))
        end
        patch_work_yaml(number, year, edition_data.merge(general))
        patch_part_yamls(number, year, edition_data[:parts] || [])
      end
    end

    def ensure_parent_work_yaml(number, year, data)
      stem = "r#{number}_#{year}"
      work_docid = "OIML R #{number}:#{year}"
      parent_titles = caco3_edition_titles(number, year)

      hash = {
        "id" => "R#{number}-#{year}",
        "type" => "standard",
        "title" => parent_titles.empty? ? [{ "language" => "eng", "content" => general_title(number, data), "type" => "main" }] : parent_titles,
        "docidentifier" => [{ "content" => work_docid, "type" => "OIML", "primary" => true }],
        "docnumber" => number.to_s,
        "date" => [{ "type" => "published", "from" => "#{year}-01-01" }],
        "contributor" => [OimlFetcher.oiml_publisher_contributor],
        "language" => ["eng", "fra"],
        "script" => ["Latn"],
        "status" => { "stage" => { "content" => data[:status] || "in-force" } },
        "ext" => { "doctype" => { "content" => "recommendation" }, "flavor" => "oiml" },
      }
      hash["ext"]["scope"] = data[:scope] if data[:scope]
      hash["ext"]["doi"] = data[:doi] if data[:doi]
      if data[:high_priority]
        hash["ext"]["high_priority"] = true
        hash["ext"]["high_priority_source"] = "https://www.oiml.org/en/publications/oiml-bulletin/2026-01/20260111"
      end
      @yaml_store.write(stem, hash)
    end

    def general_title(number, data)
      "OIML Recommendation #{number}"
    end

    def caco3_edition_titles(number, year)
      html = fetch_html("#{BASE_URL}/recommendation/#{number}/#{year}/")
      doc = Nokogiri::HTML(html)
      head = doc.at_css("h1")&.text&.strip
      head ? [{ "language" => "eng", "content" => head.sub(/\ARecommendation\s+R\s*\d+\s*[:-]?\s*/i, "").strip, "type" => "main" }] : []
    rescue OimlFetcher::Http::BadStatus
      []
    end

    def fetch_editions(number)
      html = fetch_html("#{BASE_URL}/recommendation/#{number}/")
      doc = Nokogiri::HTML(html)
      doc.css("a[href*=\"/recommendation/#{number}/\"]").map do |a|
        a["href"][%r{/recommendation/#{number}/(\d{4})/}, 1]
      end.compact.uniq.sort
    end

    def fetch_general_metadata(number)
      html = fetch_html("#{BASE_URL}/recommendation/#{number}/")
      parse_general(Nokogiri::HTML(html))
    end

    def fetch_edition_page(number, year)
      html = fetch_html("#{BASE_URL}/recommendation/#{number}/#{year}/")
      doc = Nokogiri::HTML(html)
      parse_edition(doc, number, year)
    rescue OimlFetcher::Http::BadStatus
      nil
    end

    # ---- Parsers ----

    def parse_general(doc)
      {
        quantity: text_after_b(doc, "Quantity"),
        measuring_instrument: text_after_b(doc, "Measuring Instrument"),
        focus_area: focus_area(doc),
        sustainability_framework: sustainability(doc),
        scope: scope_text(doc),
        high_priority: high_priority?(doc),
      }
    end

    def high_priority?(doc)
      doc.at_css('a.btn[href*="oiml-bulletin"][href*="2026-01"]').to_s.include?("High Priority")
    end

    def parse_edition(doc, number, year)
      {
        doi: doi_from(doc),
        scope: scope_text(doc),
        parts: parts_from(doc, number, year),
        quantity: text_after_b(doc, "Quantity"),
        measuring_instrument: text_after_b(doc, "Measuring Instrument"),
        focus_area: focus_area(doc),
        sustainability_framework: sustainability(doc),
        status: status_from(doc),
      }
    end

    def text_after_b(doc, label)
      node = doc.at_css("p b:contains('#{label}')")
      return nil unless node && node.parent

      full_text = node.parent.text.strip
      full_text.sub(/\A#{Regexp.escape(label)}\s*:?\s*/, "")
    end

    def scope_text(doc)
      text_after_b(doc, "Scope")
    end

    def focus_area(doc)
      btn = doc.at_css("p:contains('OIML Focus Area') a.btn")
      return nil unless btn

      btn.text.strip
    end

    def sustainability(doc)
      img = doc.at_css("p:contains('3Ps Sustainability Framework') img")
      return nil unless img

      img["alt"]&.strip
    end

    def doi_from(doc)
      btn = doc.at_css("button[data-doi]")
      return nil unless btn

      doi = btn["data-doi"]
      doi.sub(%r{\Ahttps?://doi\.org/}, "")
    end

    def parts_from(doc, number, year)
      # Part links on an edition page can point to OTHER years
      # (e.g. R 35:2007 page links to /35/2007/1/, /35/2011/2/, /35/2011/3/).
      # Walk every part link discovered on this page, regardless of year.
      seen = {}
      doc.css("a[href*=\"/recommendation/#{number}/\"]").each do |a|
        href = a["href"]
        m = href.match(%r{/recommendation/#{number}/(\d{4})/(\d+)/})
        next unless m

        part_year = m[1].to_i
        part_num = m[2].to_i
        seen[[part_num, part_year]] ||= a.text.strip
      end
      seen.sort.map do |(num, part_year), title|
        fetch_part_details(number, part_year, num, title)
      end
    end

    def fetch_part_details(number, year, part_num, fallback_title)
      html = fetch_html("#{BASE_URL}/recommendation/#{number}/#{year}/#{part_num}/")
      doc = Nokogiri::HTML(html)
      downloads = {}
      doc.css('a[href*="/static/files/"][href$=".pdf"]').each do |a|
        href = a["href"]
        lang = href[%r{/static/files/([a-z]{2})/}, 1]
        next unless lang

        full = href.start_with?("/") ? "#{BASE_URL}#{href}" : href
        downloads[lang] = full
      end
      { number: part_num, year: year, title: parse_part_title(doc) || fallback_title, downloads: downloads }
    rescue OimlFetcher::Http::BadStatus
      { number: part_num, year: year, title: fallback_title, downloads: {} }
    end

    def parse_part_title(doc)
      node = doc.at_css("h1")
      return nil unless node

      text = node.text.strip
      text.sub(/\ARecommendation\s+R\s*\d+.*?\z/i, "").strip
    end

    def status_from(doc)
      status = text_after_b(doc, "Status")
      return nil unless status

      case status
      when /current/i then "in-force"
      when /superseded/i then "superseded"
      when /withdrawn/i then "withdrawn"
      else status.downcase
      end
    end

    # ---- YAML patching ----

    def patch_work_yaml(number, year, data)
      stem = "r#{number}_#{year}"
      return unless @yaml_store.exist?(stem)

      @yaml_store.patch(stem) do |hash|
        hash["ext"] ||= { "flavor" => "oiml" }
        hash["ext"]["doctype"] ||= { "content" => "recommendation" }
        hash["ext"]["scope"] = data[:scope] if data[:scope]
        hash["ext"]["quantity"] = data[:quantity] if data[:quantity]
        hash["ext"]["measuring_instrument"] = data[:measuring_instrument] if data[:measuring_instrument]
        hash["ext"]["focus_area"] = data[:focus_area] if data[:focus_area]
        hash["ext"]["sustainability_framework"] = data[:sustainability_framework] if data[:sustainability_framework]
        hash["ext"]["doi"] = data[:doi] if data[:doi]
        if data[:high_priority]
          hash["ext"]["high_priority"] = true
          hash["ext"]["high_priority_source"] = "https://www.oiml.org/en/publications/oiml-bulletin/2026-01/20260111"
        end
        hash
      end
    end

    def patch_part_yamls(number, year, parts)
      return if parts.empty?

      parent_stem = "r#{number}_#{year}"
      return unless @yaml_store.exist?(parent_stem)

      parent = @yaml_store.read(parent_stem)
      parent_docid = parent["docidentifier"].find { |d| d["type"] == "OIML" && d["primary"] }&.dig("content")
      return unless parent_docid

      parts.each do |part|
        part_year = part[:year] || year
        patch_part_work(number, part_year, part, parent_docid, parent)
        patch_part_instances(number, part_year, part)
        link_parent_to_part(parent_stem, number, part_year, part[:number])
      end
    end

    def patch_part_work(number, year, part, parent_docid, parent)
      stem = "r#{number}-#{part[:number]}-#{year}"
      work_docid = "OIML R #{number}-#{part[:number]}:#{year}"
      if @yaml_store.exist?(stem)
        @yaml_store.patch(stem) do |hash|
          hash["title"] = [{ "language" => "eng", "content" => part[:title], "type" => "main" }] if part[:title]
          hash
        end
        return
      end

      hash = {
        "id" => "R#{number}-#{part[:number]}-#{year}",
        "type" => "standard",
        "title" => [{ "language" => "eng", "content" => part[:title], "type" => "main" }],
        "docidentifier" => [{ "content" => work_docid, "type" => "OIML", "primary" => true }],
        "docnumber" => number.to_s,
        "date" => [{ "type" => "published", "from" => "#{year}-01-01" }],
        "contributor" => parent["contributor"] || [OimlFetcher.oiml_publisher_contributor],
        "language" => part_language(part),
        "script" => ["Latn"],
        "status" => parent["status"] || { "stage" => { "content" => "in-force" } },
        "relation" => [{
          "type" => "partOf",
          "bibitem" => { "docidentifier" => [{ "content" => parent_docid, "type" => "OIML" }] },
        }],
        "ext" => { "doctype" => { "content" => "recommendation" }, "flavor" => "oiml" },
      }
      @yaml_store.write(stem, hash)
    end

    def patch_part_instances(number, year, part)
      downloads = part[:downloads] || {}
      downloads.each do |lang_code, url|
        lang = LANG_MAP.fetch(lang_code, lang_code)
        patch_part_instance(number, year, part, lang, url)
      end
    end

    def patch_part_instance(number, year, part, lang, url)
      stem = "r#{number}-#{part[:number]}-#{year}_#{lang}"
      work_docid = "OIML R #{number}-#{part[:number]}:#{year}"
      return if @yaml_store.exist?(stem)

      lang_suffix = OimlFetcher::DOCID_LANG_CODE.fetch(lang)
      hash = {
        "id" => "R#{number}-#{part[:number]}-#{year}-#{lang}",
        "type" => "standard",
        "source" => [OimlFetcher::Source.url(url)],
        "docidentifier" => [{ "content" => "#{work_docid} (#{lang_suffix})", "type" => "OIML", "primary" => true }],
        "docnumber" => number.to_s,
        "date" => [{ "type" => "published", "from" => "#{year}-01-01" }],
        "contributor" => [OimlFetcher.oiml_publisher_contributor],
        "language" => [lang],
        "script" => ["Latn"],
        "status" => { "stage" => { "content" => "in-force" } },
        "relation" => [{
          "type" => "instanceOf",
          "bibitem" => { "docidentifier" => [{ "content" => work_docid, "type" => "OIML" }] },
        }],
        "ext" => { "doctype" => { "content" => "recommendation" }, "flavor" => "oiml" },
      }
      @yaml_store.write(stem, hash)
    end

    def link_parent_to_part(parent_stem, number, part_year, part_num)
      part_docid = "OIML R #{number}-#{part_num}:#{part_year}"
      @yaml_store.patch(parent_stem) do |data|
        data["relation"] ||= []
        next data if data["relation"].any? { |r| r["type"] == "hasPart" && r.dig("bibitem", "docidentifier", 0, "content") == part_docid }

        data["relation"] << {
          "type" => "hasPart",
          "bibitem" => { "docidentifier" => [{ "content" => part_docid, "type" => "OIML" }] },
        }
        data
      end
    end

    def part_language(part)
      langs = (part[:downloads] || {}).keys.map { |k| LANG_MAP.fetch(k, k) }
      langs.empty? ? ["eng", "fra"] : langs.uniq
    end

    LANG_MAP = { "en" => "eng", "fr" => "fra" }.freeze

    # ---- HTTP ----

    def fetch_html(url)
      @http.backend.get(url, headers: { "Accept" => "text/html" })
    end

    def say(msg)
      $stdout.puts msg
    end
  end
end
