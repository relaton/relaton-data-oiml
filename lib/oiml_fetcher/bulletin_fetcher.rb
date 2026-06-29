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
      slugs = issues || enumerate_html_issues
      volumes = Hash.new { |h, y| h[y] = { roman: nil, issues: [] } }

      slugs.each do |slug|
        data = process_issue(slug)
        next unless data

        volumes[data[:year]][:roman] ||= data[:roman]
        volumes[data[:year]][:issues] << data
      rescue OimlFetcher::Http::Error => e
        warn "  Skipping bulletin issue #{slug}: #{e.message}"
      end

      volume_docids = volumes.keys.sort.map { |year| write_volume(year, volumes[year]) }
      write_bulletin(volume_docids)
      slugs
    end

    # ---- Enumeration ----------------------------------------------------

    # HTML issues live at /en/publications/oiml-bulletin/YYYY-NN (no .pdf).
    def enumerate_html_issues
      html = get("#{@base}/en/publications/oiml-bulletin/online-bulletin")
      html.scan(%r{/en/publications/oiml-bulletin/(\d{4}-\d{2})(?=["'/])})
          .flatten.uniq.sort
    end

    private

    # ---- Issue ----------------------------------------------------------

    def process_issue(slug)
      url = "#{@base}/en/publications/oiml-bulletin/#{slug}"
      doc = nokogiri(get(url))
      articles = article_links(doc, slug)
      return nil if articles.empty?

      year, nn = slug.split("-").map(&:to_i)
      roman = header_roman(doc)

      article_records = articles.map { |a| process_article(slug, a, year) }.compact
      roman ||= article_records.map { |r| r[:roman] }.compact.first

      write_issue(slug, year, nn, roman, article_records)
      { slug: slug, year: year, nn: nn, roman: roman,
        issue_docid: issue_docid(slug),
        article_docids: article_records.map { |r| r[:docid] } }
    end

    def article_links(doc, slug)
      seen = {}
      doc.css("a[href]").each do |a|
        m = a["href"].match(%r{/oiml-bulletin/#{Regexp.escape(slug)}/(\d{6,8})\z})
        next unless m

        id = m[1]
        title = a.text.strip
        # Keep the longest title seen for a given id (contents list has the full one).
        seen[id] = title if !seen.key?(id) || title.length > seen[id].length
      end
      seen.map { |id, title| { id: id, title: title } }.sort_by { |a| a[:id] }
    end

    # ---- Article --------------------------------------------------------

    def process_article(slug, link, year)
      url = "#{@base}/en/publications/oiml-bulletin/#{slug}/#{link[:id]}"
      doc = nokogiri(get(url))
      header = doc.at_css(".bulletin-header-left") || doc.at_css("#content-core")
      return nil unless header

      citation = parse_citation(header)
      seq = link[:id][-2..]
      art_docid = "#{SERIES_TITLE} #{slug}-#{seq}"
      roman = citation[:roman] || header_roman(doc)
      nn = slug.split("-").last.to_i

      hash = build_article_hash(
        slug: slug, seq: seq, id: link[:id], url: url, year: year, nn: nn,
        roman: roman, header: header, contents_title: link[:title],
      )
      @store.write(article_filename(slug, seq), hash)
      { docid: art_docid, roman: roman }
    end

    def build_article_hash(slug:, seq:, id:, url:, year:, nn:, roman:, header:, contents_title:)
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
          { "content" => id, "type" => "OIML-bulletin-article-id" },
        ],
        "contributor" => article_contributors(header),
        "language" => ["eng"],
        "script" => ["Latn"],
        "series" => [series_hash],
        "extent" => [extent_hash(roman, nn)],
        "relation" => [{
          "type" => "includedIn",
          "bibitem" => { "docidentifier" => [{ "content" => issue_docid(slug), "type" => "OIML" }] },
        }],
        "ext" => { "doctype" => { "content" => "article" }, "flavor" => "oiml" },
      }.tap do |h|
        abstract = header_abstract(header)
        h["abstract"] = [{ "language" => "eng", "script" => "Latn",
                           "format" => "text/plain", "content" => abstract }] if abstract
        apply_published!(h, year, nn)
      end
    end

    # ---- Issue / Volume / Bulletin records ------------------------------

    def write_issue(slug, year, nn, roman, article_records)
      hash = {
        "id" => "Bulletin-#{slug}",
        "type" => "journal",
        "title" => [localized(issue_title(year, nn, roman), "main")],
        "source" => [OimlFetcher::Source.url("#{@base}/en/publications/oiml-bulletin/#{slug}")],
        "docidentifier" => [{ "content" => issue_docid(slug), "type" => "OIML", "primary" => true }],
        "language" => ["eng"], "script" => ["Latn"],
        "series" => [series_hash],
        "extent" => [extent_hash(roman, nn)],
        "relation" => [parent_relation(volume_docid(year))] +
          article_records.map { |r| child_relation(r[:docid]) },
        "ext" => { "doctype" => { "content" => "issue" }, "flavor" => "oiml" },
      }
      apply_published!(hash, year, nn)
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
        "extent" => [{ "locality" => [volume_locality(roman)].compact }],
        "relation" => [parent_relation(SERIES_TITLE)] +
          info[:issues].sort_by { |i| i[:nn] }.map { |i| child_relation(i[:issue_docid]) },
        "ext" => { "doctype" => { "content" => "volume" }, "flavor" => "oiml" },
      }
      apply_published!(hash, year, nil)
      @store.write("bulletin_#{year}", hash)
      docid
    end

    def write_bulletin(volume_docids)
      hash = {
        "id" => "Bulletin",
        "type" => "journal",
        "title" => [localized(SERIES_TITLE, "main")],
        "source" => [OimlFetcher::Source.url("#{@base}/en/publications/oiml-bulletin")],
        "docidentifier" => [{ "content" => SERIES_TITLE, "type" => "OIML", "primary" => true }],
        "contributor" => [OimlFetcher.oiml_publisher_contributor],
        "language" => ["eng"], "script" => ["Latn"],
        "series" => [series_hash],
        "relation" => volume_docids.map { |d| child_relation(d) },
        "ext" => { "doctype" => { "content" => "periodical" }, "flavor" => "oiml" },
      }
      @store.write("bulletin", hash)
    end

    # ---- HTML extraction helpers ---------------------------------------

    def header_title(header)
      t = header.at_css("h1")&.text&.strip
      t unless t.nil? || t.empty?
    end

    def header_subtitle(header)
      t = header.at_css("h1 ~ h2, h2")&.text&.strip
      t unless t.nil? || t.empty?
    end

    def header_roman(doc)
      link = doc.at_css(".bulletin-header-left a, #content-core h5 a")
      txt = link && (link["text"] || link.text)
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

    def apply_published!(hash, year, nn)
      month = nn ? QUARTER_MONTH.fetch(nn, "01") : "01"
      hash["date"] = [{ "type" => "published", "from" => "#{year}-#{month}-01" }]
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
