# frozen_string_literal: true

require "open3"
require "fileutils"
require "json"

module OimlFetcher
  class PortfolioFetcher
    PORTFOLIO_MARKER = "-p-"
    HELPER = File.expand_path("../../bin/extract_portfolio.py", __dir__)

    def initialize(data_dir:, pdfs_dir:, yaml_store:, http_backend: OimlFetcher::Http.backend, force: false)
      @data_dir = File.expand_path(data_dir)
      @pdfs_dir = File.expand_path(pdfs_dir)
      @yaml_store = yaml_store
      @http_backend = http_backend
      @force = force
    end

    def run
      FileUtils.mkdir_p(@pdfs_dir)
      stats = { pdfs: 0, portfolios: 0, parts: 0, failed: 0 }

      @yaml_store.each_yaml do |name, _path|
        data = @yaml_store.read(name)
        (data["source"] || []).each do |src|
          url = src["content"]
          next unless url&.include?("oiml.org")

          begin
            s = process_source(url, name)
            stats[:pdfs] += 1 if s[:downloaded]
            stats[:portfolios] += 1 if s[:portfolio]
            stats[:parts] += s[:parts]
          rescue StandardError => e
            warn "  ERROR #{url}: #{e.message}"
            stats[:failed] += 1
          end
        end
      end

      say "PDFs: #{stats[:pdfs]}  Portfolios: #{stats[:portfolios]}  Parts: #{stats[:parts]}  Failed: #{stats[:failed]}"
    end

    private

    def process_source(url, yaml_stem)
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
        if @force
          FileUtils.rm_rf(parts_dir)
          downloaded = true
        end
        parts_count = extract_portfolio(target_path, parts_dir)
        warn "  WARN portfolio #{filename} yielded 0 parts" if parts_count.zero?
      end
      { downloaded: downloaded, portfolio: is_portfolio, parts: parts_count }
    end

    def work_directory_for(yaml_stem)
      stem = yaml_stem.sub(/_(eng|fra|deu|ara|zho|fas|pol|por|rus|srp|spa|ukr)$/, "")
      stem == yaml_stem ? yaml_stem : stem
    end

    def language_for(url, yaml_stem)
      return "eng" if url =~ /-e\d{2}\b/ || url =~ /-e\d{4}\b/
      return "fra" if url =~ /-f\d{2}\b/ || url =~ /-f\d{4}\b/

      m = yaml_stem.match(/_([a-z]{3})$/)
      m ? m[1] : "eng"
    end

    def download(url, target_path)
      if File.exist?(target_path) && File.size(target_path).positive?
        return false
      end

      FileUtils.mkdir_p(File.dirname(target_path))
      body = @http_backend.get(url)
      File.binwrite(target_path, body)
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
      write_links_sidecar(parts_dir, result["links"]) if result["links"]&.any?
      result["count"].to_i
    end

    def write_links_sidecar(parts_dir, links)
      sidecar_path = File.join(parts_dir, "links.json")
      existing = File.exist?(sidecar_path) ? (JSON.parse(File.read(sidecar_path)) rescue []) : []
      all_uris = (existing.map { |l| l["uri"] } + links.map { |l| l["uri"] }).uniq
      merged = all_uris.map { |u| { "uri" => u } }
      File.write(sidecar_path, JSON.pretty_generate(merged))
    end

    def downloaded_ok?(path)
      File.exist?(path) && File.size(path).positive?
    end

    def say(msg)
      $stdout.puts msg
    end
  end
end
