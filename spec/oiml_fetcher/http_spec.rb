# frozen_string_literal: true

require "spec_helper"

RSpec.describe OimlFetcher::Http do
  describe "::backend default" do
    after { described_class.backend = described_class::NetHttp.new }

    it "is NetHttp by default" do
      expect(described_class.backend).to be_a(described_class::NetHttp)
    end

    it "is swappable" do
      fake = described_class::Fake.new("x" => "y")
      described_class.backend = fake
      expect(described_class.backend).to be(fake)
    end
  end

  describe OimlFetcher::Http::Fake do
    it "returns the body for a known URL" do
      fake = described_class.new("https://x/y" => "body")
      expect(fake.get("https://x/y")).to eq("body")
    end

    it "raises KeyError for unknown URL" do
      fake = described_class.new
      expect { fake.get("https://x") }.to raise_error(KeyError)
    end

    it "calls a Proc fixture with the URL" do
      fake = described_class.new("https://x" => ->(url) { "got:#{url}" })
      expect(fake.get("https://x")).to eq("got:https://x")
    end
  end

  describe OimlFetcher::Http::NetHttp, :webmock do
    let(:http) { described_class.new }

    it "fetches a successful response body" do
      stub_request(:get, "https://example.test/x.json")
        .to_return(status: 200, body: '{"ok":true}')
      expect(http.get("https://example.test/x.json")).to eq('{"ok":true}')
    end

    it "follows a 302 redirect" do
      stub_request(:get, "https://example.test/old")
        .to_return(status: 302, headers: { "Location" => "https://example.test/new" })
      stub_request(:get, "https://example.test/new")
        .to_return(status: 200, body: "found")
      expect(http.get("https://example.test/old")).to eq("found")
    end

    it "raises BadStatus on 404" do
      stub_request(:get, "https://example.test/missing")
        .to_return(status: 404)
      expect { http.get("https://example.test/missing") }
        .to raise_error(OimlFetcher::Http::BadStatus)
    end

    it "raises TooManyRedirects after the redirect limit" do
      stub_request(:get, /example.test\/loop/)
        .to_return(status: 302, headers: { "Location" => "https://example.test/loop" })
      expect { http.get("https://example.test/loop", redirects: 3) }
        .to raise_error(OimlFetcher::Http::TooManyRedirects)
    end
  end
end
