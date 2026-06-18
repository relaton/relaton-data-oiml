# frozen_string_literal: true

module OimlFetcher
  # Scrapes the 10 other-language translation HTML tables on oiml.org and
  # emits one Relaton YAML per translation PDF. Each translation instance
  # points back at its English canonical item via a `translatedFrom` relation.
  #
  # Translation pages are server-rendered HTML (`table.colour`), NOT the
  # React JSON API. See AGENTS.md.
  #
  # Translation refs include part numbers (R 35-1:2007) that don't exist in
  # the JSON API. We still emit a YAML for each translation; the
  # `translatedFrom` relation points at the English instance of the base ref
  # (R 35:2007 (eng)) — or the work, if no English instance exists.
  class TranslationFetcher
    def initialize(data_dir:)
      @data_dir = File.expand_path(data_dir)
    end

    def run
      OimlFetcher::TRANSLATION_LANGS.each do |lang|
        fetch_language(lang)
      end
    end

    private

    def fetch_language(lang)
      url = "#{OimlFetcher::BASE_URL}/en/publications/other-language-translations/#{lang}/#{lang}"
      doc = Nokogiri::HTML(fetch_body(url))

      rows = doc.css("table.colour tr").drop(1)
      warn "  #{lang}: #{rows.length} translation rows"
      rows.each do |tr|
        tds = tr.css("td")
        next if tds.length < 3

        anchor = tds[0].at_css("a")
        next unless anchor

        translated_ref = tds[0].text.squish
        pdf_url = anchor["href"]
        title = tds[1].text.squish
        origin = tds[2].text.squish
        write_translation(translated_ref, pdf_url, title, origin, lang)
      end
    end

    def write_translation(translated_ref, pdf_url, title, origin, lang)
      lang_code = OimlFetcher::LANG_CODE.fetch(lang)
      docid_suffix = OimlFetcher::DOCID_LANG_CODE.fetch(lang_code)
      base_docid = "OIML #{strip_locale_suffix(translated_ref)}"
      translation_docid = "OIML #{translated_ref} (#{docid_suffix})"
      source_ref_docid = "#{base_docid} (E)"

      hash = {
        "id" => id_for(translated_ref, lang_code),
        "type" => "standard",
        "title" => [{ "language" => lang_code, "content" => title, "type" => "main" }],
        "source" => [{ "type" => "website", "content" => full_url(pdf_url) }],
        "docidentifier" => [{
          "content" => translation_docid,
          "type" => "OIML",
          "primary" => true,
        }],
        "docnumber" => translated_ref[/\d+/],
        "contributor" => [{
          "role" => [{ "type" => "translator" }],
          "organization" => { "name" => [{ "content" => origin }] },
        }],
        "language" => [lang_code],
        "script" => [script_for(lang)],
        "status" => { "stage" => { "content" => "in-force" } },
        "relation" => [{
          "type" => "translatedFrom",
          "bibitem" => { "docidentifier" => [{ "content" => source_ref_docid, "type" => "OIML" }] },
        }],
        "ext" => { "doctype" => { "content" => "translation" }, "flavor" => "oiml" },
      }

      if (year = translated_ref[/:(\d{4})/, 1])
        hash["date"] = [{ "type" => "published", "from" => "#{year}-01-01" }]
        hash["copyright"] = [{
          "from" => year,
          "owner" => [{ "organization" => {
            "name" => [{ "content" => OimlFetcher::OIML_NAME }],
            "abbreviation" => { "content" => OimlFetcher::OIML_ABBR },
          } }],
        }]
      end

      path = File.join(@data_dir, filename_for(translated_ref, lang_code))
      item = Relaton::Bib::Item.from_hash(hash)
      File.write(path, item.to_yaml, encoding: "UTF-8")
    rescue StandardError => e
      warn "  ERROR building #{translated_ref} (#{lang}): #{e.message}"
      warn "  #{e.backtrace.first(3).join("\n  ")}"
    end

    def strip_locale_suffix(ref)
      ref.sub(/-en\z/, "").sub(/-fr\z/, "").sub(/-de\z/, "").sub(/-\w{2,3}\z/, "")
    end

    def id_for(translated_ref, lang)
      base = translated_ref.gsub(/\s+/, "").tr(":", "-")
      "#{base}-#{lang}"
    end

    def filename_for(translated_ref, lang)
      stem = translated_ref.downcase.gsub(/\s+/, "").tr(":/", "-").gsub(/[^a-z0-9-]+/, "-").gsub(/^-+|-+$/, "")
      "#{stem}_#{lang}.yaml"
    end

    def script_for(lang)
      case lang
      when "arabic", "persian" then "Arab"
      when "chinese" then "Hans"
      when "russian", "serbian", "ukrainian" then "Cyrl"
      else "Latn"
      end
    end

    def full_url(path)
      path.start_with?("http") ? path : "#{OimlFetcher::BASE_URL}/#{path}"
    end

    def fetch_body(url)
      uri = URI(url)
      Net::HTTP.start(uri.host, uri.port, use_ssl: uri.scheme == "https") do |http|
        fetch_with_redirects(http, uri, 0)
      end
    end

    def fetch_with_redirects(http, uri, depth, limit = 5)
      raise "Too many redirects from #{uri}" if depth >= limit

      res = http.get(uri.request_uri)
      case res
      when Net::HTTPSuccess then res.body
      when Net::HTTPRedirection
        loc = res["location"]
        next_uri = loc.start_with?("http") ? URI(loc) : uri.merge(loc)
        fetch_with_redirects(http, next_uri, depth + 1, limit)
      else
        raise "HTTP #{res.code} for #{uri}"
      end
    end
  end
end
