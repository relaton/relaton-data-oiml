# frozen_string_literal: true

require "open-uri"
require "open3"
require "fileutils"
require "json"

module OimlFetcher
  # Downloads every OIML source PDF referenced from data/*.yaml into pdfs/,
  # and extracts embedded parts from PDF Portfolio wrappers.
  #
  # Layout (see pdfs/README.md):
  #   pdfs/<work_stem>/<original-filename>.pdf
  #   pdfs/<work_stem>/parts_<lang>/<extracted-part>.pdf
  class PortfolioFetcher
    PORTFOLIO_MARKER = "-p-"
    HELPER = File.expand_path("../../bin/extract_portfolio.py", __dir__)

    def initialize(data_dir:, pdfs_dir:)
      @data_dir = File.expand_path(data_dir)
      @pdfs_dir = File.expand_path(pdfs_dir)
    end

    def run
      FileUtils.mkdir_p(@pdfs_dir)
      yaml_paths = Dir[File.join(@data_dir, "*.yaml")].sort
      say "Scanning #{yaml_paths.length} data files for source URLs"

      stats = { pdfs: 0, portfolios: 0, parts: 0, skipped: 0, failed: 0 }
      yaml_paths.each do |yaml_path|
        s = process_yaml(yaml_path)
        stats.each_key { |k| stats[k] += s[k] }
      end
      print_summary(stats)
    end

    private

    def process_yaml(yaml_path)
      stats = zero_stats
      data = YAML.safe_load(File.read(yaml_path, encoding: "UTF-8"))
      sources = data["source"] || []
      return stats if sources.empty?

      sources.each do |src|
        url = src["content"]
        next unless url&.include?("oiml.org")

        begin
          downloaded, is_portfolio, parts_count = process_source(url, yaml_path)
          stats[:pdfs] += 1 if downloaded
          stats[:portfolios] += 1 if is_portfolio
          stats[:parts] += parts_count
        rescue StandardError => e
          warn "  ERROR #{url}: #{e.message}"
          stats[:failed] += 1
        end
      end
      stats
    end

    def process_source(url, yaml_path)
      yaml_stem = File.basename(yaml_path, ".yaml")
      work_dir = work_directory_for(yaml_stem)
      lang = language_for(url, yaml_stem)
      filename = File.basename(URI.parse(url).path)

      target_dir = File.join(@pdfs_dir, work_dir)
      target_path = File.join(target_dir, filename)
      downloaded = download(url, target_path)

      is_portfolio = filename.include?(PORTFOLIO_MARKER) || portfolio?(target_path)
      parts_count = 0
      if is_portfolio && downloaded_ok?(target_path)
        parts_dir = File.join(target_dir, "parts_#{lang}")
        parts_count = extract_portfolio(target_path, parts_dir)
      end
      [downloaded, is_portfolio, parts_count]
    end

    def work_directory_for(yaml_stem)
      # r35_2007_eng → r35_2007 ; r35-1-2007_deu → r35-1-2007 ; r35_2007 → r35_2007
      stem = yaml_stem.sub(/_(eng|fra|deu|ara|zho|fas|pol|por|rus|srp|spa|ukr)$/, "")
      stem == yaml_stem ? yaml_stem : stem
    end

    def language_for(url, yaml_stem)
      # Prefer URL hint (e07=English, f07=French); fall back to YAML stem suffix.
      return "eng" if url =~ /-e\d{2}\b/ || url =~ /-e\d{4}\b/
      return "fra" if url =~ /-f\d{2}\b/ || url =~ /-f\d{4}\b/

      m = yaml_stem.match(/_([a-z]{3})$/)
      m ? m[1] : "eng"
    end

    def download(url, target_path)
      return false if File.exist?(target_path) && File.size(target_path).positive?

      FileUtils.mkdir_p(File.dirname(target_path))
      say "    ↓ #{File.basename(target_path)}"
      URI.open(url, "r", read_timeout: 30, open_timeout: 15) do |remote|
        File.binwrite(target_path, remote.read)
      end
      true
    rescue StandardError => e
      warn "    download failed: #{e.message}"
      false
    end

    def portfolio?(pdf_path)
      return false unless File.exist?(pdf_path)
      return false if File.size(pdf_path) < 1000

      out, status = Open3.capture2("python3", HELPER, pdf_path)
      return false unless status.success?

      JSON.parse(out)["count"].to_i.positive?
    rescue StandardError
      false
    end

    def extract_portfolio(pdf_path, parts_dir)
      FileUtils.mkdir_p(parts_dir)
      out, status = Open3.capture2("python3", HELPER, pdf_path, parts_dir)
      raise "extract_portfolio.py failed" unless status.success?

      result = JSON.parse(out)
      result["count"].to_i
    end

    def downloaded_ok?(path)
      File.exist?(path) && File.size(path).positive?
    end

    def zero_stats
      { pdfs: 0, portfolios: 0, parts: 0, skipped: 0, failed: 0 }
    end

    def print_summary(stats)
      say "Summary:"
      say "  PDFs downloaded/cached:   #{stats[:pdfs]}"
      say "  Portfolios detected:      #{stats[:portfolios]}"
      say "  Parts extracted:          #{stats[:parts]}"
      say "  Failed:                   #{stats[:failed]}"
    end

    def say(msg)
      $stdout.puts msg
    end
  end
end
