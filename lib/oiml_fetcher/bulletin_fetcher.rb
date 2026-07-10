# frozen_string_literal: true

module OimlFetcher
  # Fetches OIML Bulletin *articles* from the HTML editions on oiml.org and
  # emits a four-tier Relaton hierarchy:
  #
  #   bulletin.yaml            — the periodical (type: journal)
  #     hasPart →
  #   bulletin_2026.yaml       — a volume / year (type: journal)
  #     hasPart →
  #   bulletin_2026-02.yaml    — an issue (type: journal)
  #     hasPart →
  #   bulletin_2026-02-11.yaml — an article (type: article)
  #
  # Containment is bidirectional (hasPart downward, partOf/includedIn upward),
  # mirroring the work/instance hasInstance/instanceOf pattern used elsewhere.
  # Each article is also self-describing via +series+ (OIML Bulletin) and
  # +extent.locality+ (volume/issue[/page]) so it stands alone, BIPM-Metrologia
  # style.
  #
  # This is the *maintained* path: only the HTML editions are ongoing. The
  # historical PDF/OCR/docx backfill lives in backfill/ as one-off scripts.
  class BulletinFetcher
    SERIES_TITLE = "OIML Bulletin"
    # Quarterly: issue NN -> first month of its quarter.
    QUARTER_MONTH = { 1 => "01", 2 => "04", 3 => "07", 4 => "10" }.freeze

    # "2026 - VOLUME LXVII - NUMBER 2"
    HEADER_RE = /(\d{4})\s*-\s*VOLUME\s+([IVXLCDM]+)\s*-\s*NUMBER\s+(\d+)/i
    # "Citation: G. Ardimento 2026 OIML Bulletin LXVII(2) 20260211"
    CITATION_RE = /Citation:\s*(.+?)\s+(\d{4})\s+OIML\s+Bulletin\s+([IVXLCDM]+)\((\d+)\)\s+(\d{6,8})/i

    def initialize(yaml_store:, http_backend: OimlFetcher::Http.backend,
                   base_url: OimlFetcher::BASE_URL)
      @store = yaml_store
      @http = http_backend
      @base = base_url
    end

    # issues: explicit ["2026-02", ...] or nil to auto-enumerate HTML editions.
    def run(issues: nil)
      issue_list =
        if issues
          issues.map { |slug| { "slug" => slug, "prefix" => "" } }
        else
          enumerate_html_issues
        end
      volumes = Hash.new { |h, y| h[y] = { roman: nil, issues: [] } }

      issue_list.each do |info|
        data = process_issue(info["slug"], info["prefix"])
        next unless data

        volumes[data[:year]][:roman] ||= data[:roman]
        volumes[data[:year]][:issues] << data
      rescue OimlFetcher::Http::Error => e
        warn "  Skipping bulletin issue #{info['slug']}: #{e.message}"
      end

      volume_docids = volumes.keys.sort.map { |year| write_volume(year, volumes[year]) }
      write_bulletin(volume_docids)
      issue_list
    end
    # ---- Enumeration ----------------------------------------------------

    # HTML issues live at /en/publications/oiml-bulletin/YYYY-NN (canonical)
    # or /en/publications/oiml-bulletin/online-bulletin-1/YYYY-NN (a 2024
    # transitional subpath used for the 2024-07 and 2024-10 editions).
    # Returns an array of {slug, prefix} hashes.
    def enumerate_html_issues
      html = get("#{@base}/en/publications/oiml-bulletin/online-bulletin")
      html.scan(%r{/en/publications/oiml-bulletin/(online-bulletin-1/)?(\d{4}-\d{2})(?=["'/])})
          .map { |prefix, slug| { "slug" => slug, "prefix" => prefix.to_s } }
          .uniq.sort_by { |h| h["slug"] }
    end

    private

    # ---- Issue ----------------------------------------------------------

    def process_issue(slug, prefix = "")
      sub = prefix.empty? ? "" : "#{prefix}"
      url = "#{@base}/en/publications/oiml-bulletin/#{sub}#{slug}"
      doc = nokogiri(get(url))
      articles = article_links(doc, slug, prefix)
      return nil if articles.empty?

      year, nn = slug.split("-").map(&:to_i)
      roman = header_roman(doc)
      # Canonical-era slugs use quarterly numbering (1-4); 2024 transitional
      # slugs use literal months (1, 4, 7, 10). Compute the actual month.
      month = prefix.empty? ? QUARTER_MONTH.fetch(nn, "01") : format("%02d", nn)

      article_records = articles.each_with_index.map do |a, idx|
        process_article(slug, prefix, a, year, idx)
      end.compact
      roman ||= article_records.map { |r| r[:roman] }.compact.first

      write_issue(slug, year, nn, roman, article_records, month)
      { slug: slug, year: year, nn: nn, roman: roman,
        issue_docid: issue_docid(slug),
        article_docids: article_records.map { |r| r[:docid] } }
    end

    def article_links(doc, slug, prefix = "")
      seen = {}
      # Article URLs may be /oiml-bulletin/<slug>/<id> (canonical) or
      # /oiml-bulletin/online-bulletin-1/<slug>/<id> (transitional).
      # The <id> may be a 6-8 digit number (canonical era) or a kebab-case
      # slug (2024 transitional era).
      pattern = %r{/oiml-bulletin/#{Regexp.escape(prefix)}#{Regexp.escape(slug)}/([^/"?#]+)\z}
      doc.css("a[href]").each do |a|
        m = a["href"].match(pattern)
        next unless m

        id = m[1]
        # Skip pseudo-routes that aren't articles.
        next if id == "editorial" || id == "focus-paper"

        title = a.text.strip
        seen[id] = title if !seen.key?(id) || title.length > seen[id].length
      end
      seen.map { |id, title| { id: id, title: title } }.sort_by { |a| a[:id] }
    end

    # ---- Article --------------------------------------------------------

    def process_article(slug, prefix, link, year, idx)
      sub = prefix.empty? ? "" : prefix
      url = "#{@base}/en/publications/oiml-bulletin/#{sub}#{slug}/#{link[:id]}"
      doc = nokogiri(get(url))
      header = doc.at_css(".bulletin-header-left") || doc.at_css("#content-core")
      return nil unless header

      citation = parse_citation(header)
      # Canonical-era article IDs embed the sequence in their last 2 digits
      # (e.g. 20260211 -> 11). Slug-based IDs (2024 transitional era) don't,
      # so use the enumeration index for those.
      seq = link[:id].match?(/\A\d{6,8}\z/) ? link[:id][-2..] : format("%02d", idx + 1)
      art_docid = "#{SERIES_TITLE} #{slug}-#{seq}"
      roman = citation[:roman] || header_roman(doc)
      nn = slug.split("-").last.to_i
      # Canonical-era slugs use quarterly numbering (1-4); 2024 transitional
      # slugs use literal months (1, 4, 7, 10).
      month = prefix.empty? ? QUARTER_MONTH.fetch(nn, format("%02d", nn)) : format("%02d", nn)

      hash = build_article_hash(
        slug: slug, seq: seq, id: link[:id], url: url, year: year, month: month,
        roman: roman, header: header, contents_title: link[:title],
      )
      @store.write(article_filename(slug, seq), hash)
      { docid: art_docid, roman: roman }
    end

    def build_article_hash(slug:, seq:, id:, url:, year:, month:, roman:, header:, contents_title:)
      title = header_title(header) || contents_title
      subtitle = header_subtitle(header)
      titles = [localized(title, "main")]
      titles << localized(subtitle, "subtitle") if subtitle && subtitle != title

      {
        "id" => "Bulletin-#{slug}-#{seq}",
        "type" => "article",
        "title" => titles,
        "source" => [OimlFetcher::Source.url(url)],
        "docidentifier" => [
          { "content" => "#{SERIES_TITLE} #{slug}-#{seq}", "type" => "OIML", "primary" => true },
          { "content" => id, "type" => "OIML-bulletin-url-slug" },
        ],
        "contributor" => article_contributors(header),
        "language" => ["eng"],
        "script" => ["Latn"],
        "series" => [series_hash],
        "extent" => [extent_hash(roman, month_to_issue(month))],
        "relation" => [{
          "type" => "includedIn",
          "bibitem" => { "docidentifier" => [{ "content" => issue_docid(slug), "type" => "OIML" }] },
        }],
        "ext" => { "doctype" => { "content" => "article" }, "flavor" => "oiml" },
      }.tap do |h|
        abstract = header_abstract(header)
        h["abstract"] = [{ "language" => "eng", "script" => "Latn",
                           "format" => "text/plain", "content" => abstract }] if abstract
        apply_published!(h, year, month)
      end
    end

    # ---- Issue / Volume / Bulletin records ------------------------------

    def write_issue(slug, year, nn, roman, article_records, month)
      hash = {
        "id" => "Bulletin-#{slug}",
        "type" => "journal",
        "title" => [localized(issue_title(year, nn, roman), "main")],
        "source" => [OimlFetcher::Source.url("#{@base}/en/publications/oiml-bulletin/#{slug}")],
        "docidentifier" => [{ "content" => issue_docid(slug), "type" => "OIML", "primary" => true }],
        "language" => ["eng"], "script" => ["Latn"],
        "series" => [series_hash],
        "extent" => [extent_hash(roman, month_to_issue(month))],
        "relation" => [parent_relation(volume_docid(year))] +
          article_records.map { |r| child_relation(r[:docid]) },
        "ext" => { "doctype" => { "content" => "issue" }, "flavor" => "oiml" },
      }
      apply_published!(hash, year, month)
      @store.write("bulletin_#{slug}", hash)
    end

    def write_volume(year, info)
      roman = info[:roman]
      docid = volume_docid(year)
      hash = {
        "id" => "Bulletin-#{year}",
        "type" => "journal",
        "title" => [localized(volume_title(year, roman), "main")],
        "docidentifier" => [{ "content" => docid, "type" => "OIML", "primary" => true }],
        "language" => ["eng"], "script" => ["Latn"],
        "series" => [series_hash],
        "relation" => [parent_relation(SERIES_TITLE)] +
          info[:issues].sort_by { |i| i[:nn] }.map { |i| child_relation(i[:issue_docid]) },
        "ext" => { "doctype" => { "content" => "volume" }, "flavor" => "oiml" },
      }
      hash["extent"] = [{ "locality" => [volume_locality(roman)] }] if roman
      apply_published!(hash, year, nil)
      @store.write("bulletin_#{year}", hash)
      docid
    end

    def write_bulletin(volume_docids)
      require "set"
      # Preserve any hasPart relations already on the bulletin record (e.g.
      # docx-spine volumes from load_to_data.rb) instead of overwriting.
      existing_has_parts = []
      if @store.exist?("bulletin")
        begin
          existing = @store.read("bulletin")
          existing_has_parts = (existing["relation"] || []).select { |r| r["type"] == "hasPart" }
        rescue StandardError
          nil
        end
      end

      new_targets = volume_docids.to_set
      preserved = existing_has_parts.reject do |r|
        docid = r.dig("bibitem", "docidentifier", 0, "content")
        new_targets.include?(docid)
      end

      hash = {
        "id" => "Bulletin",
        "type" => "journal",
        "title" => [localized(SERIES_TITLE, "main")],
        "source" => [OimlFetcher::Source.url("#{@base}/en/publications/oiml-bulletin")],
        "docidentifier" => [{ "content" => SERIES_TITLE, "type" => "OIML", "primary" => true }],
        "contributor" => [OimlFetcher.oiml_publisher_contributor],
        "language" => ["eng"], "script" => ["Latn"],
        "series" => [series_hash],
        "relation" => preserved + volume_docids.map { |d| child_relation(d) },
        "ext" => { "doctype" => { "content" => "periodical" }, "flavor" => "oiml" },
      }
      @store.write("bulletin", hash)
    end

    # ---- HTML extraction helpers ---------------------------------------

    def header_title(header)
      # Canonical era uses h1; 2024 transitional era uses h2.
      %w[h1 h2].each do |tag|
        t = header.at_css(tag)&.text&.strip
        return t unless t.nil? || t.empty?
      end
      nil
    end

    def header_subtitle(header)
      # Only return an h2 as subtitle if an h1 is present (canonical era).
      # The 2024 transitional era uses h2 for the title itself.
      return nil unless header.at_css("h1")

      t = header.css("h2").map { |h| h.text.strip }.find { |x| !x.empty? }
      t
    end

    def header_roman(doc)
      # Try the link-text form first (canonical era), then plain h5 text (2024 era).
      link = doc.at_css(".bulletin-header-left a, #content-core h5 a")
      txt = link && (link["text"] || link.text) || doc.at_css(".bulletin-header-left h5, #content-core h5")&.text
      m = txt && HEADER_RE.match(txt)
      m && m[2].upcase
    end

    def parse_citation(header)
      h6 = header.css("h6").map(&:text).find { |t| t.include?("Citation") }
      m = h6 && CITATION_RE.match(h6)
      return {} unless m

      { author: m[1].strip, year: m[2].to_i, roman: m[3].upcase,
        issue: m[4].to_i, id: m[5] }
    end

    # Authors are <p><strong>Name</strong></p>; affiliation is the following
    # plain <p>. Returns relaton contributor hashes (authors + OIML publisher).
    def article_contributors(header)
      authors = header.css("p strong").map { |s| s.text.strip }.reject(&:empty?)
      affiliation = header.css("p").reject { |p| p.at_css("strong") }
                          .map { |p| p.text.strip }.reject(&:empty?).first
      contribs = authors.map { |name| person_contributor(name, affiliation) }
      contribs << OimlFetcher.oiml_publisher_contributor
      contribs
    end

    def person_contributor(name, affiliation)
      person = { "name" => { "completename" => { "content" => name } } }
      if affiliation && !affiliation.empty?
        person["affiliation"] = [{ "organization" => { "name" => [{ "content" => affiliation }] } }]
      end
      { "role" => [{ "type" => "author" }], "person" => person }
    end

    def header_abstract(header)
      body = header.parent&.at_css(".bulletin-body") ||
             header.document.at_css(".bulletin-body")
      p = body&.at_css("p")
      txt = p&.text&.strip
      return nil if txt.nil? || txt.empty?

      txt.length > 500 ? "#{txt[0, 497].rstrip}..." : txt
    end

    # ---- Value helpers --------------------------------------------------

    def series_hash
      { "title" => [{ "content" => SERIES_TITLE, "language" => "eng",
                      "script" => "Latn", "format" => "text/plain" }] }
    end

    def extent_hash(roman, nn)
      { "locality" => [volume_locality(roman),
                       { "type" => "issue", "reference_from" => nn.to_s }].compact }
    end

    # Map a month string ("01".."12") to a quarterly issue number (1..4).
    def month_to_issue(month)
      { "01" => 1, "04" => 2, "07" => 3, "10" => 4 }.fetch(month, month.to_i)
    end

    def volume_locality(roman)
      return nil unless roman

      { "type" => "volume", "reference_from" => roman }
    end

    def localized(content, type)
      { "language" => "eng", "script" => "Latn", "content" => content, "type" => type }
    end

    def parent_relation(docid)
      { "type" => "partOf", "bibitem" => { "docidentifier" => [{ "content" => docid, "type" => "OIML" }] } }
    end

    def child_relation(docid)
      { "type" => "hasPart", "bibitem" => { "docidentifier" => [{ "content" => docid, "type" => "OIML" }] } }
    end

    def apply_published!(hash, year, month)
      # month is a 2-digit string ("01".."12") or nil for volume-level records.
      m = month || "01"
      hash["date"] = [{ "type" => "published", "from" => "#{year}-#{m}-01" }]
      hash["copyright"] = [{
        "from" => year.to_s,
        "owner" => [{ "organization" => OimlFetcher.oiml_org_hash }],
      }]
    end

    # ---- Identifiers ----------------------------------------------------

    def issue_docid(slug) = "#{SERIES_TITLE} #{slug}"
    def volume_docid(year) = "#{SERIES_TITLE} #{year}"
    def article_filename(slug, seq) = "bulletin_#{slug}-#{seq}"

    def issue_title(year, nn, roman)
      vol = roman ? "Volume #{roman}, " : ""
      "#{SERIES_TITLE}, #{vol}Number #{nn} (#{year})"
    end

    def volume_title(year, roman)
      vol = roman ? "Volume #{roman} " : ""
      "#{SERIES_TITLE}, #{vol}(#{year})"
    end

    # ---- I/O ------------------------------------------------------------

    def get(url) = @http.get(url, headers: { "User-Agent" => "relaton-data-oiml" })
    def nokogiri(body) = Nokogiri::HTML(body)
  end
end
