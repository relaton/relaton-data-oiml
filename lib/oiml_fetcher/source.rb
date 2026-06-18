# frozen_string_literal: true

module OimlFetcher
  # Value object that produces a relaton-compatible +source+ hash with the
  # correct +type+ for the kind of location it represents. Two constructors
  # remove the "local path tagged as website" class of bug.
  class Source
    def self.url(url)
      { "type" => "website", "content" => url }
    end

    def self.oiml(path)
      full = path.start_with?("http") ? path : "#{OimlFetcher::BASE_URL}/#{path}"
      url(full)
    end

    def self.local(path)
      { "type" => "file", "content" => path }
    end
  end
end
