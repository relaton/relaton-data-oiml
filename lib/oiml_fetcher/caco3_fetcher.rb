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

        patch_work_yaml(number, year, edition_data.merge(general))
        patch_part_yamls(number, year, edition_data[:parts] || [])
      end
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
      }
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
      links = doc.css("a[href*=\"/recommendation/#{number}/#{year}/\"]")
      links.map do |a|
        href = a["href"]
        part_num = href[%r{/recommendation/#{number}/#{year}/(\d+)/}, 1]
        next nil unless part_num

        { number: part_num.to_i, title: a.text.strip }
      end.compact
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
        hash
      end
    end

    def patch_part_yamls(number, year, parts)
      parts.each do |part|
        stem = "r#{number}-#{part[:number]}-#{year}"
        next unless @yaml_store.exist?(stem)

        @yaml_store.patch(stem) do |hash|
          hash["title"] = [{ "language" => "eng", "content" => part[:title], "type" => "main" }]
          hash
        end
      end
    end

    # ---- HTTP ----

    def fetch_html(url)
      @http.backend.get(url, headers: { "Accept" => "text/html" })
    end

    def say(msg)
      $stdout.puts msg
    end
  end
end
