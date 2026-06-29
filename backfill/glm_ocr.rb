# frozen_string_literal: true

# One-off: OCR scanned OIML Bulletin PDFs (1960s–1990s) via z.ai GLM-OCR.
# NOT maintained. NOT in lib/, CI, or cron. Reads the API key from
# ~/.zai-api-key at runtime — never hardcodes it, never commits it.
#
# Run:
#   Z_AI_API_KEY="$(cat ~/.zai-api-key)" bundle exec ruby backfill/glm_ocr.rb <pdf_url_or_path> [<start>] [<end>]
#
# API: https://docs.z.ai/api-reference/tools/layout-parsing.md
#   POST https://api.z.ai/api/paas/v4/layout_parsing
#   body: { model: "glm-ocr", file: <url|base64>, start_page_id:, end_page_id: }
#   limits: PDF <= 50MB, <= 30 pages per request.
#
# Output: backfill/cache/<sha(ocr_input)>.json with the full API response,
# plus a concatenated markdown file at backfill/cache/<sha>.md.

require "net/http"
require "json"
require "digest"
require "fileutils"
require "base64"

module BulletinBackfill
  class GlmOcr
    ENDPOINT = URI("https://api.z.ai/api/paas/v4/layout_parsing").freeze
    PAGES_PER_CHUNK = 30
    CACHE_DIR = File.expand_path("cache", __dir__)

    def initialize(api_key: ENV.fetch("Z_AI_API_KEY") { File.read(File.expand_path("~/.zai-api-key")).strip })
      @api_key = api_key
      FileUtils.mkdir_p(CACHE_DIR)
    end

    # OCR an entire PDF by chunking into 30-page windows. Returns combined
    # markdown. Caches each chunk by (url, window) so re-runs are free.
    def ocr_pdf(file_input, num_pages:)
      (1..num_pages).each_slice(PAGES_PER_CHUNK).map do |window|
        chunk(file_input, window.first, window.min(window.last))
      end.join("\n\n")
    end

    # Single chunk. file_input is a URL string or local path.
    def chunk(file_input, start_page, end_page)
      cache_key = cache_key_for(file_input, start_page, end_page)
      cached = read_cache(cache_key)
      return cached["md_results"] if cached

      res = request(file_input, start_page, end_page)
      write_cache(cache_key, res)
      warn "  OCR #{describe(file_input)} pages #{start_page}-#{end_page}: #{res.dig('usage', 'total_tokens')} tokens"
      res["md_results"] || ""
    end

    private

    def request(file_input, start_page, end_page)
      body = { "model" => "glm-ocr", "file" => as_file_field(file_input),
               "start_page_id" => start_page, "end_page_id" => end_page }
      http = Net::HTTP.new(ENDPOINT.host, ENDPOINT.port, use_ssl: true)
      http.read_timeout = 180
      req = Net::HTTP::Post.new(ENDPOINT.request_uri,
                                "Authorization" => "Bearer #{@api_key}",
                                "Content-Type" => "application/json")
      req.body = JSON.generate(body)
      res = http.request(req)
      raise "GLM-OCR HTTP #{res.code}: #{res.body[0, 300]}" unless res.is_a?(Net::HTTPSuccess)

      JSON.parse(res.body).tap do |j|
        raise "GLM-OCR error: #{j.inspect}" if j["error"] || j["code"]
      end
    end

    def as_file_field(input)
      return input if input.start_with?("http")

      "data:application/pdf;base64,#{Base64.strict_encode64(File.binread(input))}"
    end

    def describe(input) = input.start_with?("http") ? input : File.basename(input)

    def cache_key_for(input, start_page, end_page)
      Digest::SHA256.hexdigest("#{input}|#{start_page}|#{end_page}")[0, 16]
    end

    def read_cache(key)
      path = File.join(CACHE_DIR, "#{key}.json")
      return nil unless File.exist?(path)

      JSON.parse(File.read(path))
    end

    def write_cache(key, data)
      File.write(File.join(CACHE_DIR, "#{key}.json"), JSON.generate(data))
    end
  end
end

if $PROGRAM_NAME == __FILE__
  input = ARGV[0] || abort("usage: glm_ocr.rb <pdf_url_or_path> [<num_pages>]")
  num_pages = (ARGV[1] || 30).to_i
  md = BulletinBackfill::GlmOcr.new.ocr_pdf(input, num_pages: num_pages)
  key = Digest::SHA256.hexdigest(input)[0, 16]
  out = File.join(BulletinBackfill::GlmOcr::CACHE_DIR, "#{key}.md")
  File.write(out, md)
  puts "Wrote #{out} (#{md.size} chars)"
end
