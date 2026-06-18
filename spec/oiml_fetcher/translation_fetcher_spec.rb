# frozen_string_literal: true

require "spec_helper"
require "tmpdir"

RSpec.describe OimlFetcher::TranslationFetcher do
  let(:dir) { Dir.mktmpdir("oiml-trans") }
  after { FileUtils.rm_rf(dir) }

  let(:html_page) do
    <<~HTML
      <html><body>
      <table class="colour">
      <tr><th>Ref</th><th>Title</th><th>Origin</th></tr>
      <tr>
        <td><a href="/en/publications/other-language-translations/german/r035-1-de-07.pdf">R 35-1:2007</a></td>
        <td>Material measures Part 1</td>
        <td>PTB</td>
      </tr>
      </table></body></html>
    HTML
  end

  let(:fake_http) do
    OimlFetcher::Http::Fake.new(
      "https://www.oiml.org/en/publications/other-language-translations/german/german" => html_page,
    )
  end

  let(:store) { OimlFetcher::YamlStore.new(dir) }

  it "emits a translation YAML with correct docid and translatedFrom relation" do
    described_class.new(data_dir: dir, yaml_store: store, http_backend: fake_http, langs: %w[german]).run

    files = Dir[File.join(dir, "*.yaml")]
    expect(files.length).to eq(1)

    data = YAML.safe_load(File.read(files.first))
    expect(data["docidentifier"].first["content"]).to eq("OIML R 35-1:2007 (D)")
    expect(data["language"]).to eq(%w[deu])
    expect(data["relation"].first["type"]).to eq("translatedFrom")
    expect(data["contributor"].first["role"].first["type"]).to eq("translator")
    expect(data["contributor"].first["organization"]["name"].first["content"]).to eq("PTB")
  end

  it "uses clean_ref to extract OIML docid from mixed ref+title cells" do
    mixed_html = <<~HTML
      <html><body><table class="colour">
      <tr><th>Ref</th><th>Title</th><th>Origin</th></tr>
      <tr>
        <td nowrap="nowrap"><a href="/x.pdf">OIML B 18, Operational Documents</a></td>
        <td>Framework for OIML-CS</td>
        <td>NIM</td>
      </tr>
      </table></body></html>
    HTML
    http = OimlFetcher::Http::Fake.new(
      "https://www.oiml.org/en/publications/other-language-translations/chinese/chinese" => mixed_html,
    )
    described_class.new(data_dir: dir, yaml_store: store, http_backend: http, langs: %w[chinese]).run

    data = YAML.safe_load(File.read(Dir[File.join(dir, "*.yaml")].first))
    expect(data["id"]).to eq("B18-zho")
    expect(data["docidentifier"].first["content"]).to eq("OIML B 18 (C)")
  end
end
