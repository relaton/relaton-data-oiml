# frozen_string_literal: true

# One-off: load parsed docx entries into data/ as a 4-tier bulletin hierarchy.
# NOT maintained. NOT in lib/, CI, or cron.
#
# Reads:  backfill/cache/docx_articles.yaml (from docx_contents.rb)
# Writes: data/bulletin_<year>.yaml            (volume record, with roman)
#         data/bulletin_<year>-<issue>.yaml    (issue record)
#         data/bulletin_<year>-<issue>-<seq>.yaml (article record)
#         (and updates data/bulletin.yaml to list all volumes)
#
# Skips entries already covered by the HTML era (year >= 2025).
#
# Run:
#   bundle exec ruby backfill/load_to_data.rb

$LOAD_PATH.unshift(File.expand_path("../lib", __dir__))
require "oiml_fetcher"
require "yaml"

module BulletinBackfill
  class LoadToData
    HTML_ERA_START_YEAR = 2025
    FRENCH_HINTS = /[À-ɏ]|\b(?:le|la|les|des|du|de|une?|à|et|dans|pour|par|sur|au|aux|ce|cette|est|son|sa|ses|avec)\b/i

    attr_reader :counts

    def initialize(data_dir:, store: nil)
      @data_dir = data_dir
      @store = store || OimlFetcher::YamlStore.new(data_dir)
      @counts = Hash.new(0)
    end

    def load(entries_path = File.expand_path("cache/docx_articles.yaml", __dir__))
      entries = YAML.load_file(entries_path)
      entries.each { |e| assign_within_year_issue_no(entries, e) }

      docx_entries = entries.reject { |e| (e["year"] || 0) >= HTML_ERA_START_YEAR }
                            .reject { |e| e["issue_no"].nil? && e["bulletin_no"].nil? }

      volumes = build_volumes(docx_entries)
      write_volume_records(volumes)
      write_issue_records(volumes)
      write_article_records(volumes)
      patch_bulletin_record(volumes.keys)

      @counts[:total_entries] = docx_entries.size
      self
    end

    private

    # Pre-1994 entries have cumulative bulletin_no but no issue_no. Assign a
    # within-year issue number by sorting bulletin_no within each year.
    def assign_within_year_issue_no(all, entry)
      return if entry["issue_no"]

      by_year = all.select { |e| e["year"] == entry["year"] }
                   .map { |e| e["bulletin_no"] }.compact.uniq.sort
      idx = by_year.index(entry["bulletin_no"])
      entry["issue_no"] = idx && idx + 1
    end

    def build_volumes(entries)
      entries.group_by { |e| e["year"] }.transform_values do |es|
        roman = es.map { |e| e["volume_roman"] }.compact.first
        {
          roman: roman,
          entries: es,
          issues: es.group_by { |e| e["issue_no"] }.sort.to_h,
        }
      end
    end

    def write_volume_records(volumes)
      volumes.each do |year, info|
        roman = info[:roman]
        issue_docids = info[:issues].keys.sort.map { |n| "OIML Bulletin #{year}-#{fmt(n)}" }
        hash = {
          "id" => "Bulletin-#{year}",
          "type" => "journal",
          "title" => [title_with_roman("OIML Bulletin", roman, year)],
          "docidentifier" => [{ "content" => "OIML Bulletin #{year}", "type" => "OIML", "primary" => true }],
          "date" => [{ "type" => "published", "from" => "#{year}-01-01" }],
          "contributor" => [OimlFetcher.oiml_publisher_contributor],
          "language" => ["eng", "fra"], "script" => ["Latn"],
          "copyright" => [{ "from" => year.to_s,
                            "owner" => [{ "organization" => OimlFetcher.oiml_org_hash }] }],
          "series" => [series_hash],
          "relation" => [parent_relation("OIML Bulletin")] +
                        issue_docids.map { |d| child_relation(d) },
          "ext" => { "doctype" => { "content" => "volume" }, "flavor" => "oiml" },
        }
        hash["extent"] = [{ "locality" => [{ "type" => "volume", "reference_from" => roman }] }] if roman
        @store.write("bulletin_#{year}", hash)
        @counts[:volumes] += 1
      end
    end

    def write_issue_records(volumes)
      volumes.each do |year, info|
        info[:issues].each do |issue_no, entries|
          slug = "#{year}-#{fmt(issue_no)}"
          roman = info[:roman]
          month = entries.map { |e| e["month"] }.compact.first || quarter_month(issue_no)
          article_docids = entries.sort_by { |e| e["sequence"] }
                                   .map { |e| "OIML Bulletin #{slug}-#{e['sequence']}" }
          hash = {
            "id" => "Bulletin-#{slug}",
            "type" => "journal",
            "title" => [title_with_roman_and_issue("OIML Bulletin", roman, issue_no, year)],
            "docidentifier" => [{ "content" => "OIML Bulletin #{slug}", "type" => "OIML", "primary" => true }],
            "date" => [{ "type" => "published", "from" => "#{year}-#{fmt(month, 2)}-01" }],
            "contributor" => [OimlFetcher.oiml_publisher_contributor],
            "language" => ["eng", "fra"], "script" => ["Latn"],
            "copyright" => [{ "from" => year.to_s,
                              "owner" => [{ "organization" => OimlFetcher.oiml_org_hash }] }],
            "series" => [series_hash],
            "relation" => [parent_relation("OIML Bulletin #{year}")] +
                          article_docids.map { |d| child_relation(d) },
            "ext" => { "doctype" => { "content" => "issue" }, "flavor" => "oiml" },
          }
          localities = [{ "type" => "issue", "reference_from" => issue_no.to_s }]
          localities.unshift("type" => "volume", "reference_from" => roman) if roman
          hash["extent"] = [{ "locality" => localities }]
          @store.write("bulletin_#{slug}", hash)
          @counts[:issues] += 1
        end
      end
    end

    def write_article_records(volumes)
      volumes.each do |year, info|
        info[:issues].each do |issue_no, entries|
          slug = "#{year}-#{fmt(issue_no)}"
          roman = info[:roman]
          entries.sort_by { |e| e["sequence"] }.each do |e|
            @store.write("bulletin_#{slug}-#{e['sequence']}", article_hash(slug, roman, issue_no, e))
            @counts[:articles] += 1
          end
        end
      end
    end

    def article_hash(slug, roman, issue_no, entry)
      lang = french?(entry["title"]) ? "fra" : "eng"
      title = entry["title"] || entry["raw"]
      contributors = [OimlFetcher.oiml_publisher_contributor]
      if entry["author"]
        person = { "name" => { "completename" => { "content" => entry["author"] } } }
        if entry["country"]
          person["affiliation"] = [{ "organization" => { "name" => [{ "content" => entry["country"] }] } }]
        end
        contributors << { "role" => [{ "type" => "author" }], "person" => person }
      end
      localities = [{ "type" => "issue", "reference_from" => issue_no.to_s }]
      localities.unshift("type" => "volume", "reference_from" => roman) if roman
      {
        "id" => "Bulletin-#{slug}-#{entry['sequence']}",
        "type" => "article",
        "title" => [{ "language" => lang, "script" => "Latn", "content" => title, "type" => "main" }],
        "docidentifier" => [
          { "content" => "OIML Bulletin #{slug}-#{entry['sequence']}", "type" => "OIML", "primary" => true },
        ],
        "date" => [{ "type" => "published", "from" => year_from_slug(slug) }],
        "contributor" => contributors,
        "language" => [lang], "script" => ["Latn"],
        "series" => [series_hash],
        "extent" => [{ "locality" => localities }],
        "relation" => [{
          "type" => "includedIn",
          "bibitem" => { "docidentifier" => [{ "content" => "OIML Bulletin #{slug}", "type" => "OIML" }] },
        }],
        "note" => [{ "content" => "Source: OIML Bulletin contents index (editor-provided docx, 2023-07-24). Raw: #{entry['raw'][0, 180]}", "type" => "source" }],
        "ext" => { "doctype" => { "content" => entry["category"] || "article" }, "flavor" => "oiml",
                   "provenance" => ["docx"] },
      }
    end

    # Patch the existing bulletin.yaml to include all volumes as hasPart.
    def patch_bulletin_record(years)
      path = File.join(@data_dir, "bulletin.yaml")
      return unless File.exist?(path)

      hash = YAML.safe_load(File.read(path, encoding: "UTF-8"))
      existing = (hash["relation"] || []).select { |r| r["type"] == "hasPart" }
                                          .map { |r| r["bibitem"]["docidentifier"].first["content"] }
      targets = (existing + years.sort.map { |y| "OIML Bulletin #{y}" }).uniq.sort
      other = (hash["relation"] || []).reject { |r| r["type"] == "hasPart" }
      hash["relation"] = other + targets.map { |d| child_relation(d) }
      @store.write("bulletin", hash)
    end

    # ---- Helpers ----

    def fmt(n, width = 2) = n.to_s.rjust(width, "0")

    def french?(text)
      text && text.match?(FRENCH_HINTS)
    end

    def quarter_month(issue_no)
      { 1 => 1, 2 => 4, 3 => 7, 4 => 10 }.fetch(issue_no, 1)
    end

    def year_from_slug(slug)
      slug[/^\d{4}/]
    end

    def title_with_roman(series, roman, year)
      vol = roman ? "Volume #{roman} " : ""
      content = "#{series}, #{vol}(#{year})"
      { "language" => "eng", "script" => "Latn", "content" => content, "type" => "main" }
    end

    def title_with_roman_and_issue(series, roman, issue_no, year)
      vol = roman ? "Volume #{roman}, " : ""
      content = "#{series}, #{vol}Number #{issue_no} (#{year})"
      { "language" => "eng", "script" => "Latn", "content" => content, "type" => "main" }
    end

    def series_hash
      { "title" => [{ "content" => "OIML Bulletin", "language" => "eng",
                      "script" => "Latn", "format" => "text/plain" }] }
    end

    def parent_relation(docid)
      { "type" => "partOf", "bibitem" => { "docidentifier" => [{ "content" => docid, "type" => "OIML" }] } }
    end

    def child_relation(docid)
      { "type" => "hasPart", "bibitem" => { "docidentifier" => [{ "content" => docid, "type" => "OIML" }] } }
    end
  end
end

if $PROGRAM_NAME == __FILE__
  loader = BulletinBackfill::LoadToData.new(data_dir: File.expand_path("../data", __dir__))
  loader.load
  c = loader.counts
  puts "Loaded docx-spine into data/:"
  puts "  entries processed: #{c[:total_entries]}"
  puts "  volumes: #{c[:volumes]}"
  puts "  issues: #{c[:issues]}"
  puts "  articles: #{c[:articles]}"
end
