# frozen_string_literal: true

module OimlFetcher
  # Fetches publication metadata from the oiml.org JSON API and emits Relaton
  # YAML files following a work + instance model:
  #
  #   r35_2007.yaml        — the work (OIML R 35:2007), no source, links to
  #                          its instances via hasInstance
  #   r35_2007_en.yaml     — English instance, source = English PDF
  #   r35_2007_fr.yaml     — French instance, source = French PDF
  #
  # Genuinely bilingual publications (single combined PDF, e.g. V 1) stay as
  # one YAML with language: [en, fr].
  class PublicationFetcher
    def initialize(data_dir:, types:, statuses:)
      @data_dir = File.expand_path(data_dir)
      @types = types
      @statuses = statuses
    end

    def run
      FileUtils.mkdir_p(@data_dir)
      @types.each do |segment|
        fetch_type(segment)
      end
    end

    private

    def fetch_type(segment)
      p_type, prefix, fr_segment, doctype = OimlFetcher::TYPES.fetch(segment)
      merged = collect_publications(segment, fr_segment, p_type)

      merged.each_value do |pair|
        pub_en = pair[:en]
        pub_fr = pair[:fr]
        if pub_en && pub_fr && separate_pdfs?(pub_en, pub_fr)
          write_work_and_instances(pub_en, pub_fr, prefix, doctype)
        else
          write_single(pub_en || pub_fr, pub_en, pub_fr, prefix, doctype)
        end
      end
    end

    def collect_publications(segment, fr_segment, p_type)
      merged = {}
      @statuses.each do |status|
        %w[en fr].each do |lang|
          url_segment = lang == "fr" ? fr_segment : segment
          url = "#{OimlFetcher::BASE_URL}/#{lang}/publications/#{url_segment}/" \
                "@@API/publications?id_type=#{p_type}&id_status=#{status}"
          fetch_json(url)["publications"].each do |pub|
            merged[pub["id"]] ||= {}
            merged[pub["id"]][lang.to_sym] = pub
          end
        rescue StandardError => e
          warn "  Skipping #{lang}/#{segment}/status=#{status}: #{e.message}"
        end
      end
      merged
    end

    def separate_pdfs?(pub_en, pub_fr)
      file_en = File.basename(pub_en["url_en"] || pub_en["url"] || "")
      file_fr = File.basename(pub_fr["url"] || pub_fr["url_en"] || "")
      !file_en.empty? && file_en != file_fr
    end

    def write_work_and_instances(pub_en, pub_fr, prefix, doctype)
      work_hash = build_work_hash(pub_en, pub_fr, prefix, doctype)
      write_yaml(work_hash, filename_for(work_hash, nil))

      en_hash = build_instance_hash(pub_en, pub_fr, "eng", prefix, doctype, work_hash)
      write_yaml(en_hash, filename_for(en_hash, "eng"))

      fr_hash = build_instance_hash(pub_fr, pub_en, "fra", prefix, doctype, work_hash)
      write_yaml(fr_hash, filename_for(fr_hash, "fra"))
    rescue StandardError => e
      ref = pub_en["ref"] || pub_fr["ref"]
      warn "  ERROR building work/instances for #{ref}: #{e.message}"
      warn "  #{e.backtrace.first(5).join("\n  ")}"
    end

    def write_single(pub, pub_en, pub_fr, prefix, doctype)
      hash = build_single_hash(pub, pub_en, pub_fr, prefix, doctype)
      write_yaml(hash, filename_for(hash, nil))
    rescue StandardError => e
      warn "  ERROR building #{pub['ref'] || pub['id']}: #{e.message}"
      warn "  #{e.backtrace.first(5).join("\n  ")}"
    end

    # ---- Hash builders ----

    def build_work_hash(pub_en, pub_fr, prefix, doctype)
      titles = []
      titles << localized_title(pub_en, "eng") if pub_en && pub_en["title"]
      titles << localized_title(pub_fr, "fra") if pub_fr && pub_fr["title"]
      titles.uniq!

      ref_en = pub_en["ref"] || pub_fr["ref"] || ""
      year = (pub_en || pub_fr)["edition_en"] || (pub_en || pub_fr)["edition"]
      docid = docid_from((pub_en || pub_fr)["shortTitle"] || ref_en)

      hash = {
        "id" => id_for(docid, nil),
        "type" => "standard",
        "title" => titles,
        "docidentifier" => [{
          "content" => docid,
          "type" => "OIML",
          "primary" => true,
        }],
        "docnumber" => ref_en[/\d+/],
        "contributor" => contributors((pub_en || pub_fr)["scTitle"]),
        "language" => titles.map { |t| t["language"] }.uniq,
        "script" => ["Latn"],
        "status" => { "stage" => { "content" => status_name((pub_en || pub_fr)["idStatus"]) } },
        "ext" => { "doctype" => { "content" => doctype }, "flavor" => "oiml" },
      }
      apply_year!(hash, year)
      add_instance_relations!(hash, docid)
      hash
    end

    def build_instance_hash(pub, other_pub, lang, prefix, doctype, work_hash)
      title = pub["title"] ? [localized_title(pub, lang)] : []
      url = lang == "eng" ? (pub["url_en"] || pub["url"]) : (pub["url"] || pub["url_en"])
      year = pub["edition_en"] || pub["edition"]
      work_docid = work_hash["docidentifier"].first["content"]
      docid_suffix = OimlFetcher::DOCID_LANG_CODE.fetch(lang)

      hash = {
        "id" => id_for(work_docid, docid_suffix),
        "type" => "standard",
        "title" => title,
        "source" => url && !url.empty? ? [{ "type" => "website", "content" => full_url(url) }] : [],
        "docidentifier" => [{
          "content" => "#{work_docid} (#{docid_suffix})",
          "type" => "OIML",
          "primary" => true,
        }],
        "docnumber" => work_hash["docnumber"],
        "contributor" => contributors(pub["scTitle"]),
        "language" => [lang],
        "script" => ["Latn"],
        "status" => { "stage" => { "content" => status_name(pub["idStatus"]) } },
        "relation" => [{
          "type" => "instanceOf",
          "bibitem" => relation_bibitem(work_docid),
        }],
        "ext" => { "doctype" => { "content" => doctype }, "flavor" => "oiml" },
      }
      apply_year!(hash, year)
      hash
    end

    def build_single_hash(pub, pub_en, pub_fr, prefix, doctype)
      ref = pub["ref"] || ""
      year = pub["edition_en"] || pub["edition"]
      docid = docid_from(pub["shortTitle"] || ref)

      titles = []
      titles << localized_title(pub_en, "eng") if pub_en && pub_en["title"]
      titles << localized_title(pub_fr, "fra") if pub_fr && pub_fr["title"]
      titles.uniq!

      url = pub["url_en"] || pub["url"]
      languages = titles.map { |t| t["language"] }.uniq

      hash = {
        "id" => id_for(docid, nil),
        "type" => "standard",
        "title" => titles,
        "source" => url && !url.empty? ? [{ "type" => "website", "content" => full_url(url) }] : [],
        "docidentifier" => [{
          "content" => docid,
          "type" => "OIML",
          "primary" => true,
        }],
        "docnumber" => ref[/\d+/],
        "contributor" => contributors(pub["scTitle"]),
        "language" => languages,
        "script" => ["Latn"],
        "status" => { "stage" => { "content" => status_name(pub["idStatus"]) } },
        "ext" => { "doctype" => { "content" => doctype }, "flavor" => "oiml" },
      }
      apply_year!(hash, year)
      hash
    end

    # ---- Helpers ----

    def apply_year!(hash, year)
      return unless year

      hash["date"] = [{ "type" => "published", "from" => "#{year}-01-01" }]
      hash["version"] = [{ "revision_date" => "#{year}-01-01" }]
      hash["copyright"] = [{
        "from" => year.to_s,
        "owner" => [{ "organization" => oiml_org_hash }],
      }]
    end

    def add_instance_relations!(hash, work_docid)
      hash["relation"] = hash["language"].map do |lang|
        suffix = OimlFetcher::DOCID_LANG_CODE.fetch(lang)
        {
          "type" => "hasInstance",
          "bibitem" => {
            "docidentifier" => [{ "content" => "#{work_docid} (#{suffix})", "type" => "OIML" }],
          },
        }
      end
    end

    def relation_bibitem(docid)
      { "docidentifier" => [{ "content" => docid, "type" => "OIML" }] }
    end

    def localized_title(pub, lang)
      { "language" => lang, "content" => pub["title"], "type" => "main" }
    end

    def status_name(id_status)
      OimlFetcher::STATUS_NAMES.fetch(id_status)
    end

    def contributors(sc_title)
      list = [{
        "role" => [{ "type" => "publisher" }],
        "organization" => oiml_org_hash,
      }]
      return list if sc_title.nil? || sc_title.empty?

      list << {
        "role" => [{ "type" => "author", "description" => [{ "content" => "committee" }] }],
        "organization" => {
          "name" => [{ "content" => OimlFetcher::OIML_NAME }],
          "subdivision" => subdivisions_for(sc_title),
          "abbreviation" => { "content" => OimlFetcher::OIML_ABBR },
        },
      }
      list
    end

    def subdivisions_for(sc_title)
      sc_title.split("/").map { |code| subdivision_for(code) }
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

    def docid_from(short_title)
      core =
        if (m = /^(.+?)\s*\((?:en|fr)\)$/.match(short_title))
          m[1]
        else
          short_title
        end
      core = core.sub(/-en\z/, "").sub(/-fr\z/, "")
      "OIML #{core}".strip
    end

    def id_for(docid, lang)
      base = docid.sub(/^OIML\s+/, "").gsub(/\s+/, "").tr(":", "-")
      lang ? "#{base}-#{lang}" : base
    end

    def filename_for(hash, lang)
      docid = hash["docidentifier"].first["content"]
      m = /^OIML\s+(.+?):(\d{4})/.match(docid) or
        raise "Unrecognized docid format: #{docid.inspect}"

      ref_part = m[1].downcase.gsub(/\s+/, "").tr("/", "-")
      suffix = lang ? "_#{lang}" : ""
      "#{ref_part}_#{m[2]}#{suffix}.yaml"
    end

    def oiml_org_hash
      {
        "name" => [{ "content" => OimlFetcher::OIML_NAME }],
        "abbreviation" => { "content" => OimlFetcher::OIML_ABBR },
      }
    end

    def full_url(path)
      return nil if path.nil? || path.empty?

      path.start_with?("http") ? path : "#{OimlFetcher::BASE_URL}/#{path}"
    end

    def write_yaml(hash, name)
      item = Relaton::Bib::Item.from_hash(hash)
      File.write(File.join(@data_dir, name), item.to_yaml, encoding: "UTF-8")
    end

    def fetch_json(url)
      uri = URI(url)
      res = Net::HTTP.start(uri.host, uri.port, use_ssl: uri.scheme == "https") do |http|
        http.get(uri.request_uri, "Accept" => "application/json")
      end
      raise "HTTP #{res.code} for #{url}" unless res.is_a?(Net::HTTPSuccess)

      JSON.parse(res.body)
    end
  end
end
