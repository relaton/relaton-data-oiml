# frozen_string_literal: true

require "spec_helper"

RSpec.describe OimlFetcher::Source do
  describe ".url" do
    it "tags a URL as website" do
      expect(described_class.url("https://example.com/x.pdf"))
        .to eq({ "type" => "website", "content" => "https://example.com/x.pdf" })
    end
  end

  describe ".oiml" do
    it "prepends BASE_URL to a relative path" do
      expect(described_class.oiml("en/files/pdf_r/r035.pdf"))
        .to eq({ "type" => "website",
                 "content" => "https://www.oiml.org/en/files/pdf_r/r035.pdf" })
    end

    it "leaves an absolute URL alone" do
      expect(described_class.oiml("https://other.example/x.pdf"))
        .to eq({ "type" => "website",
                 "content" => "https://other.example/x.pdf" })
    end
  end

  describe ".local" do
    it "tags a local path as file" do
      expect(described_class.local("pdfs/r35_2007/parts_eng/r035-1-e07.pdf"))
        .to eq({ "type" => "file",
                 "content" => "pdfs/r35_2007/parts_eng/r035-1-e07.pdf" })
    end
  end
end
