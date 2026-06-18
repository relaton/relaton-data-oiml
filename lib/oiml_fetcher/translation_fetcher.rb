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
    def initialize(data_dir:, yaml_store:, http_backend: OimlFetcher::Http.backend, langs: OimlFetcher::TRANSLATION_LANGS)
      @data_dir = File.expand_path(data_dir)
      @yaml_store = yaml_store
      @http_backend = http_backend
      @langs = langs
    end

    def run
      @langs.each do |lang|
        fetch_language(lang)
      end
    end

    private

    def fetch_language(lang)
      url = "#{OimlFetcher::BASE_URL}/en/publications/other-language-translations/#{lang}/#{lang}"
      body = @http_backend.get(url)
      doc = Nokogiri::HTML(body)

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

    def write_translation(raw_ref, pdf_url, title, origin, lang)
      lang_code = OimlFetcher::LANG_CODE.fetch(lang)
      docid_suffix = OimlFetcher::DOCID_LANG_CODE.fetch(lang_code)
      ref = clean_ref(raw_ref)
      base_docid = "OIML #{ref}"
      translation_docid = "#{base_docid} (#{docid_suffix})"
      source_ref_docid = "#{base_docid} (E)"

      hash = {
        "id" => "#{slugify(ref)}-#{lang_code}",
        "type" => "standard",
        "title" => [{ "language" => lang_code, "content" => title, "type" => "main" }],
        "source" => [OimlFetcher::Source.oiml(pdf_url)],
        "docidentifier" => [{
          "content" => translation_docid,
          "type" => "OIML",
          "primary" => true,
        }],
        "docnumber" => ref[/\d+/],
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

      if (year = ref[/:(\d{4})/, 1])
        hash["date"] = [{ "type" => "published", "from" => "#{year}-01-01" }]
        hash["copyright"] = [{
          "from" => year,
          "owner" => [{ "organization" => OimlFetcher.oiml_org_hash }],
        }]
      end

      filename = "#{slugify(ref).downcase}_#{lang_code}"
      @yaml_store.write(filename, hash)
    rescue StandardError => e
      warn "  ERROR building #{raw_ref} (#{lang}): #{e.message}"
    end

    def clean_ref(raw_cell_text)
      text = raw_cell_text.gsub(/\s+/, " ").strip
      if (m = /(?:OIML\s+)?([A-Z])\s+(\d+(?:-\d+)*)\s*(?::(\d{4}))?/.match(text))
        prefix = m[1]
        number = m[2]
        year = m[3]
        ref = year ? "#{prefix} #{number}:#{year}" : "#{prefix} #{number}"
        return ref + " Brochure" if text =~ /\bBrochure\b/i
        return ref + " Amendment" if text =~ /\bAmendment\b/i
        return ref + " Errata" if text =~ /\bErrata\b/i
        return ref
      end
      text
    end

    def slugify(ref)
      ref
        .sub(/\AOIML\s+/i, "")
        .gsub(/\s+/, "")
        .tr(":", "-")
        .gsub(/[^A-Za-z0-9-]/, "")
    end

    def script_for(lang)
      case lang
      when "arabic", "persian" then "Arab"
      when "chinese" then "Hans"
      when "russian", "serbian", "ukrainian" then "Cyrl"
      else "Latn"
      end
    end
  end
end
