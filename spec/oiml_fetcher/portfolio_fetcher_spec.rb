# frozen_string_literal: true

require "spec_helper"
require "tmpdir"

RSpec.describe OimlFetcher::PortfolioFetcher do
  let(:data_dir) { Dir.mktmpdir("oiml-pf-data") }
  let(:pdfs_dir) { Dir.mktmpdir("oiml-pf-pdfs") }
  let(:store) { OimlFetcher::YamlStore.new(data_dir) }
  after { FileUtils.rm_rf(data_dir); FileUtils.rm_rf(pdfs_dir) }

  it "downloads a PDF referenced in a data YAML source" do
    store.write("r7_1979_eng", {
      "id" => "R7-1979-E",
      "docidentifier" => [{ "content" => "OIML R 7:1979 (E)", "type" => "OIML", "primary" => true }],
      "source" => [{ "type" => "website", "content" => "https://www.oiml.org/en/files/pdf_r/r007-e79.pdf" }],
    })

    fake_http = OimlFetcher::Http::Fake.new(
      "https://www.oiml.org/en/files/pdf_r/r007-e79.pdf" => "%PDF-1.4 fake content",
    )

    described_class.new(
      data_dir: data_dir, pdfs_dir: pdfs_dir,
      yaml_store: store, http_backend: fake_http,
    ).run

    expected = File.join(pdfs_dir, "r7_1979", "r007-e79.pdf")
    expect(File.exist?(expected)).to be(true)
    expect(File.read(expected)).to include("fake content")
  end

  it "skips already-downloaded PDFs" do
    store.write("r7_1979_eng", {
      "id" => "R7-1979-E",
      "docidentifier" => [{ "content" => "OIML R 7:1979 (E)", "type" => "OIML", "primary" => true }],
      "source" => [{ "type" => "website", "content" => "https://www.oiml.org/en/files/pdf_r/r007-e79.pdf" }],
    })

    target_dir = File.join(pdfs_dir, "r7_1979")
    FileUtils.mkdir_p(target_dir)
    existing = File.join(target_dir, "r007-e79.pdf")
    File.write(existing, "already here")

    http = OimlFetcher::Http::Fake.new # empty table; would raise if called
    described_class.new(
      data_dir: data_dir, pdfs_dir: pdfs_dir,
      yaml_store: store, http_backend: http,
    ).run

    expect(File.read(existing)).to eq("already here")
  end
end
