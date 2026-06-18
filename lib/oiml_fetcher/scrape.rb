# frozen_string_literal: true

require "thor"

module OimlFetcher
  # Thor-powered CLI for fetching OIML publications and rebuilding the index.
  # Exposed via the exe/oiml-fetch binstub.
  class Scrape < Thor
    def self.exit_on_failure? = true

    default_task :fetch

    desc "fetch", "Fetch OIML publications from oiml.org into data/"
    method_option :status, type: :numeric, repeatable: true,
                            desc: "id_status to fetch (1=in-force, 5=superseded, 6=withdrawn). " \
                                  "Defaults to all three."
    method_option :translations, type: :boolean, default: false,
                                 desc: "Also fetch the 10 other-language translation pages."
    method_option :pdfs, type: :boolean, default: false,
                         desc: "Download source PDFs into pdfs/ and extract PDF Portfolio parts."
    method_option :type, type: :string, repeatable: true,
                         desc: "Restrict to one publication type (recommendations, documents, ...). " \
                               "Defaults to all seven."
    method_option :data_dir, type: :string, default: "data",
                             desc: "Output directory for YAML files."
    method_option :pdfs_dir, type: :string, default: "pdfs",
                             desc: "Output directory for cached PDFs."
    def fetch
      statuses = options[:status] || OimlFetcher::ALL_STATUSES
      types = options[:type] || OimlFetcher::TYPES.keys

      say "Fetching OIML publications (types=#{types.inspect}, statuses=#{statuses.inspect})",
          :cyan
      OimlFetcher::PublicationFetcher.new(
        data_dir: options[:data_dir],
        types: types,
        statuses: statuses,
      ).run

      if options[:translations]
        say "Fetching other-language translations...", :cyan
        OimlFetcher::TranslationFetcher.new(data_dir: options[:data_dir]).run
      end

      return unless options[:pdfs]

      say "Downloading source PDFs + extracting portfolios...", :cyan
      OimlFetcher::PortfolioFetcher.new(
        data_dir: options[:data_dir],
        pdfs_dir: options[:pdfs_dir],
      ).run

      say "Building part-level YAMLs from discovered portfolios...", :cyan
      OimlFetcher::PartsBuilder.new(
        data_dir: options[:data_dir],
        pdfs_dir: options[:pdfs_dir],
      ).run
    end

    desc "index", "Rebuild index-v1.yaml from data/*.yaml"
    method_option :data_dir, type: :string, default: "data"
    def index
      crawler = File.expand_path("../crawler.rb", repo_root)
      load crawler
    end

    private

    def repo_root
      # Walk up from lib/oiml_fetcher/scrape.rb to the repo root.
      File.expand_path("../../..", __dir__)
    end
  end
end
