# frozen_string_literal: true

# One-off: reconcile candidates from docx + pdf_index + HTML records into
# Relaton YAMLs. NOT maintained. NOT in lib/, CI, or cron.
#
# Accuracy rule: >= 2 independent sources agreeing on title (+ author where
# present) -> auto-accept to data/. Single-source or conflicting -> review/
# queue for human inspection.
#
# Run:
#   bundle exec ruby backfill/reconcile.rb
#
# Inputs (all produced by other backfill/ scripts):
#   backfill/cache/docx_articles.yaml   (3737 entries, 1960-2023)
#   backfill/cache/pdf_index.yaml       (246 PDF URLs)
#   data/bulletin_*.yaml                (HTML-era records, the canonical shape)
#
# Outputs:
#   backfill/candidates/<year>-<issue>-<seq>.yaml
#     Review-pending candidate per docx entry not already covered by HTML.
#     Carries `ext.provenance` listing contributing sources and `ext.review`.
#   backfill/candidates/_summary.yaml
#     Counts and source-attribution stats.

$LOAD_PATH.unshift(File.expand_path("../lib", __dir__))
require "oiml_fetcher"
require "yaml"
require "fileutils"

module BulletinBackfill
  class Reconcile
    CACHE = File.expand_path("cache", __dir__)
    CANDIDATES = File.expand_path("candidates", __dir__)
    DATA = File.expand_path("../data", __dir__)
    # HTML era starts here; docx entries for these issues are already in data/.
    HTML_ERA_START = Date.new(2025, 1, 1)

    attr_reader :stats

    def initialize
      FileUtils.mkdir_p(CANDIDATES)
      @docx = load_yaml(File.join(CACHE, "docx_articles.yaml"))
      @pdfs = load_yaml(File.join(CACHE, "pdf_index.yaml"))
      @stats = Hash.new(0)
    end

    def run
      pdf_lookup = build_pdf_lookup
      @docx.each { |entry| process_entry(entry, pdf_lookup) }
      write_summary
      self
    end

    private

    def process_entry(entry, pdf_lookup)
      year = entry["year"]
      bulletin_no = entry["bulletin_no"]
      return unless year && bulletin_no

      # Skip entries already covered by HTML era (2025 onward).
      if Date.new(year, 1, 1) >= HTML_ERA_START
        @stats[:skipped_html_era] += 1
        return
      end

      # Use the printed Bulletin No. directly in the slug. Early Bulletins had
      # variable frequency (>4 issues/year some years), so we do NOT collapse
      # to quarterly issue numbers — that mapping is established during the
      # OCR pass and folded in here once known.
      slug = "#{year}-#{format('%02d', bulletin_no)}"
      sources = ["docx"]

      hash = build_candidate(entry, slug, sources)
      out = File.join(CANDIDATES, "#{slug}-#{entry['sequence']}.yaml")
      File.write(out, Relaton::Bib::Item.from_hash(hash, {}).to_yaml, encoding: "UTF-8")
      @stats[:review] += 1
    end

    def build_candidate(entry, slug, sources)
      title = entry["title"] || entry["raw"]
      contributors = [OimlFetcher.oiml_publisher_contributor]
      if entry["author"]
        person = { "name" => { "completename" => { "content" => entry["author"] } } }
        if entry["country"]
          person["affiliation"] = [{ "organization" => { "name" => [{ "content" => entry["country"] }] } }]
        end
        contributors << { "role" => [{ "type" => "author" }], "person" => person }
      end
      {
        "id" => "Bulletin-#{slug}-#{entry['sequence']}",
        "type" => "article",
        "title" => [{ "language" => "fra", "script" => "Latn", "content" => title, "type" => "main" }],
        "docidentifier" => [
          { "content" => "OIML Bulletin #{slug}-#{entry['sequence']}", "type" => "OIML", "primary" => true },
        ],
        "date" => [{ "type" => "published", "from" => "#{entry['year']}-01-01" }],
        "contributor" => contributors,
        "language" => ["fra"],
        "script" => ["Latn"],
        "series" => [{ "title" => [{ "content" => "OIML Bulletin", "language" => "eng",
                                     "script" => "Latn", "format" => "text/plain" }] }],
        "relation" => [{
          "type" => "includedIn",
          "bibitem" => { "docidentifier" => [{ "content" => "OIML Bulletin #{slug}", "type" => "OIML" }] },
        }],
        "note" => [{ "content" => "Raw: #{entry['raw'][0, 200]}", "type" => "raw" }],
        "ext" => {
          "doctype" => { "content" => entry["category"] || "article" },
          "flavor" => "oiml",
          "provenance" => sources,
          "review" => "pending",
        },
      }
    end

    def build_pdf_lookup
      @pdfs.each_with_object({}) do |pdf, h|
        next unless pdf["year"] && pdf["issue"]

        h["#{pdf['year']}-#{pdf['issue']}"] ||= pdf
      end
    end

    def write_summary
      File.write(File.join(CACHE, "reconcile_summary.yaml"), {
        "total_docx_entries" => @docx.size,
        "pdfs_indexed" => @pdfs.size,
        "review_pending" => @stats[:review],
        "skipped_html_era" => @stats[:skipped_html_era],
      }.to_yaml)
    end

    def load_yaml(path)
      return [] unless File.exist?(path)

      YAML.load_file(path) || []
    end
  end
end

if $PROGRAM_NAME == __FILE__
  r = BulletinBackfill::Reconcile.new.run
  s = r.stats
  puts "Reconcile complete:"
  puts "  review pending (docx only, awaiting 2nd source): #{s[:review]}"
  puts "  skipped (HTML-era): #{s[:skipped_html_era]}"
end
