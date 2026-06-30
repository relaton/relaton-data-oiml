# frozen_string_literal: true

require "thor"

module OimlFetcher
  class Scrape < Thor
    def self.exit_on_failure? = true

    default_task :fetch

    desc "fetch", "Fetch OIML publications from oiml.org into data/"
    method_option :status, type: :numeric, repeatable: true,
                            desc: "id_status to fetch (1=in-force, 5=superseded, 6=withdrawn). Defaults to all three."
    method_option :translations, type: :boolean, default: false,
                                 desc: "Also fetch the 10 other-language translation pages."
    method_option :pdfs, type: :boolean, default: false,
                         desc: "Download source PDFs into pdfs/ and extract PDF Portfolio parts."
    method_option :caco3, type: :boolean, default: false,
                          desc: "Enrich Recommendations with metadata from oiml.caco3consulting.com."
    method_option :type, type: :string, repeatable: true,
                         desc: "Restrict to one publication type. Defaults to all seven."
    method_option :data_dir, type: :string, default: "data"
    method_option :pdfs_dir, type: :string, default: "pdfs"
    def fetch
      statuses = options[:status] || OimlFetcher::ALL_STATUSES
      types = options[:type] || OimlFetcher::TYPES.keys
      store = OimlFetcher::YamlStore.new(options[:data_dir])

      say "Fetching OIML publications (types=#{types.inspect}, statuses=#{statuses.inspect})", :cyan
      OimlFetcher::PublicationFetcher.new(
        data_dir: options[:data_dir], types: types, statuses: statuses,
        yaml_store: store,
      ).run

      if options[:translations]
        say "Fetching other-language translations...", :cyan
        OimlFetcher::TranslationFetcher.new(data_dir: options[:data_dir], yaml_store: store).run
      end

      if options[:pdfs]
        say "Downloading source PDFs + extracting portfolios...", :cyan
        OimlFetcher::PortfolioFetcher.new(
          data_dir: options[:data_dir], pdfs_dir: options[:pdfs_dir],
        ).run

        say "Building part-level YAMLs from discovered portfolios...", :cyan
        OimlFetcher::PartsBuilder.new(
          data_dir: options[:data_dir], pdfs_dir: options[:pdfs_dir],
          yaml_store: store,
        ).run
      end

      return unless options[:caco3]

      say "Enriching Recommendations from caco3consulting.com...", :cyan
      OimlFetcher::Caco3Fetcher.new(
        data_dir: options[:data_dir], yaml_store: store,
      ).run
    end

    desc "bulletin", "Fetch OIML Bulletin HTML editions into bulletin/volume/issue/article YAMLs"
    method_option :data_dir, type: :string, default: "data"
    method_option :issue, type: :string, repeatable: true,
                          desc: "Restrict to specific issues, e.g. 2026-02. Defaults to all HTML editions."
    def bulletin
      store = OimlFetcher::YamlStore.new(options[:data_dir])
      issues = options[:issue]
      say "Fetching OIML Bulletin HTML editions#{issues ? " (#{issues.join(', ')})" : ''}...", :cyan
      slugs = OimlFetcher::BulletinFetcher.new(yaml_store: store).run(issues: issues)
      say "Processed #{slugs.size} issue(s).", :green
    end

    desc "index", "Rebuild index-v1.yaml from data/*.yaml"
    def index
      load File.expand_path("../../crawler.rb", __dir__)
    end
  end
end
