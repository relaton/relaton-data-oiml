# frozen_string_literal: true

module OimlFetcher
  # Fetches publication metadata from the oiml.org JSON API and emits Relaton
  # YAML files following a work + instance model.
  #
  #   r35_2007.yaml        — work (no source, hasInstance → instances)
  #   r35_2007_eng.yaml    — English instance (source = English PDF)
  #   r35_2007_fra.yaml    — French instance
  #
  # Genuinely bilingual publications (single combined PDF, e.g. V 1) stay as
  # one YAML with language: [eng, fra].
  class PublicationFetcher
    def initialize(data_dir:, types:, statuses:, yaml_store:, http_backend: OimlFetcher::Http.backend)
      @data_dir = data_dir
      @types = types
      @statuses = statuses
      @yaml_store = yaml_store
      @http_backend = http_backend
    end

    def run
      FileUtils.mkdir_p(@data_dir)
      @types.each { |segment| fetch_type(segment) }
    end

    private

    def fetch_type(segment)
      p_type, prefix, fr_segment, doctype = OimlFetcher::TYPES.fetch(segment)
      collect_publications(segment, fr_segment, p_type).each_value do |pair|
        emit_for(pair, prefix, doctype)
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

    def emit_for(pair, prefix, doctype)
      pub_en = pair[:en]
      pub_fr = pair[:fr]
      if pub_en && pub_fr && separate_pdfs?(pub_en, pub_fr)
        write_work_and_instances(pub_en, pub_fr, doctype)
      else
        write_single(pub_en || pub_fr, pub_en, pub_fr, doctype)
      end
    end

    def separate_pdfs?(pub_en, pub_fr)
      file_en = File.basename(pub_en["url_en"] || pub_en["url"] || "")
      file_fr = File.basename(pub_fr["url"] || pub_fr["url_en"] || "")
      !file_en.empty? && file_en != file_fr
    end

    def write_work_and_instances(pub_en, pub_fr, doctype)
      work_hash = build_work_hash(pub_en, pub_fr, doctype)
      @yaml_store.write(work_filename(work_hash), work_hash)

      en_hash = build_instance_hash(pub_en, "eng", doctype, work_hash)
      @yaml_store.write(work_filename(en_hash, "eng"), en_hash)

      fr_hash = build_instance_hash(pub_fr, "fra", doctype, work_hash)
      @yaml_store.write(work_filename(fr_hash, "fra"), fr_hash)
    end

    def write_single(pub, pub_en, pub_fr, doctype)
      hash = build_single_hash(pub, pub_en, pub_fr, doctype)
      @yaml_store.write(work_filename(hash), hash)
    end

    # ---- Hash builders ----

    def build_work_hash(pub_en, pub_fr, doctype)
      pub = pub_en || pub_fr
      docid = OimlFetcher::Docid.from_short_title(pub["shortTitle"] || pub["ref"])
      titles = titles_for(pub_en, pub_fr)
      year = pub["edition_en"] || pub["edition"]

      {
        "id" => docid.id,
        "type" => "standard",
        "title" => titles,
        "docidentifier" => [{
          "content" => docid.to_s,
          "type" => "OIML",
          "primary" => true,
        }],
        "docnumber" => pub["ref"][/\d+/],
        "contributor" => contributors(pub["scTitle"]),
        "language" => titles.map { |t| t["language"] }.uniq,
        "script" => ["Latn"],
        "status" => { "stage" => { "content" => OimlFetcher::STATUS_NAMES.fetch(pub["idStatus"]) } },
        "ext" => { "doctype" => { "content" => doctype }, "flavor" => "oiml" },
      }.tap do |h|
        apply_year!(h, year)
        add_instance_relations!(h, docid)
      end
    end

    def build_instance_hash(pub, lang, doctype, work_hash)
      docid = OimlFetcher::Docid.from_short_title(pub["shortTitle"] || pub["ref"])
      title = pub["title"] ? [localized_title(pub, lang)] : []
      url = lang == "eng" ? (pub["url_en"] || pub["url"]) : (pub["url"] || pub["url_en"])
      year = pub["edition_en"] || pub["edition"]
      work_docid = work_hash["docidentifier"].first["content"]

      {
        "id" => "#{docid.id}-#{OimlFetcher::DOCID_LANG_CODE.fetch(lang)}",
        "type" => "standard",
        "title" => title,
        "source" => url && !url.empty? ? [OimlFetcher::Source.oiml(url)] : [],
        "docidentifier" => [{
          "content" => "#{work_docid} (#{OimlFetcher::DOCID_LANG_CODE.fetch(lang)})",
          "type" => "OIML",
          "primary" => true,
        }],
        "docnumber" => work_hash["docnumber"],
        "contributor" => contributors(pub["scTitle"]),
        "language" => [lang],
        "script" => ["Latn"],
        "status" => { "stage" => { "content" => OimlFetcher::STATUS_NAMES.fetch(pub["idStatus"]) } },
        "relation" => [{
          "type" => "instanceOf",
          "bibitem" => { "docidentifier" => [{ "content" => work_docid, "type" => "OIML" }] },
        }],
        "ext" => { "doctype" => { "content" => doctype }, "flavor" => "oiml" },
      }.tap { |h| apply_year!(h, year) }
    end

    def build_single_hash(pub, pub_en, pub_fr, doctype)
      docid = OimlFetcher::Docid.from_short_title(pub["shortTitle"] || pub["ref"])
      titles = titles_for(pub_en, pub_fr)
      url = pub["url_en"] || pub["url"]
      year = pub["edition_en"] || pub["edition"]

      {
        "id" => docid.id,
        "type" => "standard",
        "title" => titles,
        "source" => url && !url.empty? ? [OimlFetcher::Source.oiml(url)] : [],
        "docidentifier" => [{
          "content" => docid.to_s,
          "type" => "OIML",
          "primary" => true,
        }],
        "docnumber" => pub["ref"][/\d+/],
        "contributor" => contributors(pub["scTitle"]),
        "language" => titles.map { |t| t["language"] }.uniq,
        "script" => ["Latn"],
        "status" => { "stage" => { "content" => OimlFetcher::STATUS_NAMES.fetch(pub["idStatus"]) } },
        "ext" => { "doctype" => { "content" => doctype }, "flavor" => "oiml" },
      }.tap { |h| apply_year!(h, year) }
    end

    # ---- Helpers ----

    def titles_for(pub_en, pub_fr)
      titles = []
      titles << localized_title(pub_en, "eng") if pub_en && pub_en["title"]
      titles << localized_title(pub_fr, "fra") if pub_fr && pub_fr["title"]
      titles.uniq
    end

    def apply_year!(hash, year)
      return unless year

      hash["date"] = [{ "type" => "published", "from" => "#{year}-01-01" }]
      hash["version"] = [{ "revision_date" => "#{year}-01-01" }]
      hash["copyright"] = [{
        "from" => year.to_s,
        "owner" => [{ "organization" => OimlFetcher.oiml_org_hash }],
      }]
    end

    def add_instance_relations!(hash, docid)
      hash["relation"] = hash["language"].map do |lang|
        suffix = OimlFetcher::DOCID_LANG_CODE.fetch(lang)
        {
          "type" => "hasInstance",
          "bibitem" => {
            "docidentifier" => [{ "content" => "#{docid.to_s} (#{suffix})", "type" => "OIML" }],
          },
        }
      end
    end

    def contributors(sc_title)
      list = [OimlFetcher.oiml_publisher_contributor]
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

    def localized_title(pub, lang)
      { "language" => lang, "content" => pub["title"], "type" => "main" }
    end

    def work_filename(hash, lang = nil)
      docid_str = hash["docidentifier"].first["content"]
      m = /^OIML\s+(.+?):(\d{4})/.match(docid_str) or
        raise "Unrecognized docid format: #{docid_str.inspect}"

      ref_part = m[1].downcase.gsub(/\s+/, "").tr("/", "-")
      suffix = lang ? "_#{lang}" : ""
      "#{ref_part}_#{m[2]}#{suffix}"
    end

    def fetch_json(url)
      body = @http_backend.get(url, headers: { "Accept" => "application/json" })
      JSON.parse(body)
    end
  end
end
