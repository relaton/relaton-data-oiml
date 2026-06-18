# frozen_string_literal: true

require "spec_helper"
require "tmpdir"

RSpec.describe OimlFetcher::PublicationFetcher do
  let(:dir) { Dir.mktmpdir("oiml-pub-fetch") }
  let(:store) { OimlFetcher::YamlStore.new(dir) }
  after { FileUtils.rm_rf(dir) }

  # Stubbed JSON: one in-force Recommendation with separate EN/FR PDFs.
  let(:en_json) do
    { "lang" => "en", "pubtype" => "OIML Recommendation", "publications" => [
      { "id" => 497, "ref" => "R 35-en", "url_en" => "en/files/pdf_r/r035-p-e07.pdf",
        "url" => "en/files/pdf_r/r035-p-e07.pdf", "fileExists" => true,
        "title" => "Material measures of length for general use",
        "shortTitle" => "R 35:2007(en)", "edition" => 2007, "edition_en" => 2007,
        "idStatus" => 1, "scUrl" => "scinfo_view?idsc=56", "scTitle" => "TC7",
        "successors" => [] },
    ] }
  end
  let(:fr_json) do
    { "lang" => "fr", "pubtype" => "OIML Recommendation", "publications" => [
      { "id" => 497, "ref" => "R 35-fr", "url" => "fr/files/pdf_r/r035-p-f07.pdf",
        "url_en" => "en/files/pdf_r/r035-p-e07.pdf", "fileExists" => true,
        "title" => "Mesures matérialisées de longueur pour usages généraux",
        "shortTitle" => "R 35:2007(fr)", "edition" => 2007, "edition_en" => 2007,
        "idStatus" => 1, "scUrl" => "scinfo_view?idsc=56", "scTitle" => "TC7",
        "successors" => [] },
    ] }
  end
  let(:fake_http) do
    OimlFetcher::Http::Fake.new(
      "https://www.oiml.org/en/publications/recommendations/@@API/publications?id_type=1&id_status=1" => en_json.to_json,
      "https://www.oiml.org/fr/publications/recommandations/@@API/publications?id_type=1&id_status=1" => fr_json.to_json,
    )
  end

  it "emits work + EN instance + FR instance YAMLs with correct docids" do
    described_class.new(
      data_dir: dir, types: %w[recommendations], statuses: [1],
      yaml_store: store, http_backend: fake_http,
    ).run

    expect(store.exist?("r35_2007")).to be(true)
    expect(store.exist?("r35_2007_eng")).to be(true)
    expect(store.exist?("r35_2007_fra")).to be(true)

    work = store.read("r35_2007")
    expect(work["docidentifier"].first["content"]).to eq("OIML R 35:2007")
    expect(work["language"]).to eq(%w[eng fra])
    relations = work["relation"].map { |r| r["type"] }
    expect(relations).to include("hasInstance")
    targets = work["relation"].select { |r| r["type"] == "hasInstance" }
                              .map { |r| r["bibitem"]["docidentifier"].first["content"] }
    expect(targets).to contain_exactly("OIML R 35:2007 (E)", "OIML R 35:2007 (F)")

    en = store.read("r35_2007_eng")
    expect(en["docidentifier"].first["content"]).to eq("OIML R 35:2007 (E)")
    expect(en["language"]).to eq(%w[eng])
    expect(en["source"].first).to include(
      "type" => "website",
      "content" => "https://www.oiml.org/en/files/pdf_r/r035-p-e07.pdf",
    )
    expect(en["relation"].first["type"]).to eq("instanceOf")
  end

  it "tags TC7 as committee subdivision on the work" do
    described_class.new(
      data_dir: dir, types: %w[recommendations], statuses: [1],
      yaml_store: store, http_backend: fake_http,
    ).run

    work = store.read("r35_2007")
    author = work["contributor"].find { |c| c["role"].first["type"] == "author" }
    expect(author["organization"]["subdivision"].first["identifier"].first["content"])
      .to eq("TC7")
  end

  it "raises KeyError on unknown idStatus (no silent fallback)" do
    bad_en = { "lang" => "en", "publications" => [
      { "id" => 1, "ref" => "R 1-en", "url_en" => "x.pdf",
        "title" => "T", "shortTitle" => "R 1:2000(en)", "edition" => 2000,
        "idStatus" => 99, "scTitle" => "", "successors" => [] },
    ] }
    bad_fr = { "lang" => "fr", "publications" => [] }
    bad_http = OimlFetcher::Http::Fake.new(
      "https://www.oiml.org/en/publications/recommendations/@@API/publications?id_type=1&id_status=1" => bad_en.to_json,
      "https://www.oiml.org/fr/publications/recommandations/@@API/publications?id_type=1&id_status=1" => bad_fr.to_json,
    )
    expect {
      described_class.new(
        data_dir: dir, types: %w[recommendations], statuses: [1],
        yaml_store: store, http_backend: bad_http,
      ).run
    }.to raise_error(KeyError)
  end
end
