# frozen_string_literal: true

require "spec_helper"
require "tmpdir"

RSpec.describe OimlFetcher::PartsBuilder do
  let(:data_dir) { Dir.mktmpdir("oiml-pb-data") }
  let(:pdfs_dir) { Dir.mktmpdir("oiml-pb-pdfs") }
  let(:store) { OimlFetcher::YamlStore.new(data_dir) }
  after { FileUtils.rm_rf(data_dir); FileUtils.rm_rf(pdfs_dir) }

  it "emits part work + instance YAMLs from discovered portfolio parts" do
    parts_dir = File.join(pdfs_dir, "r35_2007", "parts_eng")
    FileUtils.mkdir_p(parts_dir)
    File.binwrite(File.join(parts_dir, "R035-1-e07.pdf"), "fake")
    File.binwrite(File.join(parts_dir, "R035-2-e11.pdf"), "fake")

    described_class.new(
      data_dir: data_dir, pdfs_dir: pdfs_dir, yaml_store: store,
    ).run

    expect(store.exist?("r35-1-2007")).to be(true)
    expect(store.exist?("r35-1-2007_eng")).to be(true)
    expect(store.exist?("r35-2-2011")).to be(true)
    expect(store.exist?("r35-2-2011_eng")).to be(true)

    part = store.read("r35-1-2007")
    expect(part["docidentifier"].first["content"]).to eq("OIML R 35-1:2007")
    expect(part["relation"].first["type"]).to eq("partOf")

    inst = store.read("r35-1-2007_eng")
    expect(inst["docidentifier"].first["content"]).to eq("OIML R 35-1:2007 (E)")
    expect(inst["relation"].first["type"]).to eq("instanceOf")
    expect(inst["source"].first["type"]).to eq("file")
  end

  it "patches the parent series YAML with hasPart relations" do
    store.write("r35_2007", {
      "id" => "R35-2007",
      "docidentifier" => [{ "content" => "OIML R 35:2007", "type" => "OIML", "primary" => true }],
      "ext" => { "doctype" => { "content" => "recommendation" }, "flavor" => "oiml" },
    })

    parts_dir = File.join(pdfs_dir, "r35_2007", "parts_eng")
    FileUtils.mkdir_p(parts_dir)
    File.binwrite(File.join(parts_dir, "R035-1-e07.pdf"), "fake")

    described_class.new(
      data_dir: data_dir, pdfs_dir: pdfs_dir, yaml_store: store,
    ).run

    work = store.read("r35_2007")
    has_part = work["relation"].select { |r| r["type"] == "hasPart" }
    expect(has_part.length).to be >= 1
    targets = has_part.map { |r| r["bibitem"]["docidentifier"].first["content"] }
    expect(targets).to include("OIML R 35-1:2007")
  end
end
