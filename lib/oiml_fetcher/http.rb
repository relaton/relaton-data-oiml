# frozen_string_literal: true

require "net/http"

module OimlFetcher
  # HTTP seam. Fetchers call +Http.backend.get(url)+; the default backend is
  # +NetHttp+ (real network). Tests install a +Fake+ with a fixture table.
  #
  # Two adapters justify the seam: real network in prod, fixture-driven in
  # tests. Redirect policy, timeouts, and error classes live in +NetHttp+
  # so callers don't reimplement them.
  module Http
    class Error < StandardError; end
    class TooManyRedirects < Error; end
    class BadStatus < Error; end
    class Timeout < Error; end

    class << self
      attr_accessor :backend
    end

    # Production adapter. Follows up to +redirects+ hops, raises on 4xx/5xx,
    # raises on read/open timeout.
    class NetHttp
      def get(url, redirects: 5, read_timeout: 30, open_timeout: 15, headers: {})
        uri = URI(url)
        fetch_with_redirects(uri, redirects, read_timeout, open_timeout, 0, headers)
      end

      private

      def fetch_with_redirects(uri, max, read_timeout, open_timeout, depth, headers)
        raise OimlFetcher::Http::TooManyRedirects, uri.to_s if depth >= max

        http = build_http(uri, read_timeout, open_timeout)
        res = http.request(build_request(uri, headers))
        case res
        when Net::HTTPSuccess then res.body
        when Net::HTTPRedirection
          next_uri = resolve_redirect(res["location"], uri)
          fetch_with_redirects(next_uri, max, read_timeout, open_timeout, depth + 1, headers)
        else
          raise OimlFetcher::Http::BadStatus, "HTTP #{res.code} for #{uri}"
        end
      rescue Net::ReadTimeout, Net::OpenTimeout
        raise OimlFetcher::Http::Timeout, uri.to_s
      end

      def build_http(uri, read_timeout, open_timeout)
        Net::HTTP.start(uri.host, uri.port,
                        use_ssl: uri.scheme == "https",
                        read_timeout: read_timeout,
                        open_timeout: open_timeout)
      end

      def build_request(uri, headers)
        Net::HTTP::Get.new(uri.request_uri, headers)
      end

      def resolve_redirect(location, base)
        location.start_with?("http") ? URI(location) : base.merge(location)
      end
    end

    # Test adapter. Returns the body for a known URL, raises otherwise.
    # +table+ maps URL strings to body strings (or a Proc called with the URL).
    class Fake
      def initialize(table = {})
        @table = table
      end

      def get(url, **_)
        entry = @table[url]
        return entry.call(url) if entry.respond_to?(:call)

        raise(KeyError, "Fake HTTP has no fixture for #{url}") unless entry

        entry
      end
    end

    self.backend = NetHttp.new
  end
end
