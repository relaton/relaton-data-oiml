# frozen_string_literal: true

require "spec_helper"
require "tmpdir"

RSpec.describe OimlFetcher::YamlStore do
  let(:dir) { Dir.mktmpdir("oiml-yaml-store") }
  let(:store) { described_class.new(dir) }

  after { FileUtils.rm_rf(dir) }

  let(:valid_item) do
    {
      "id" => "R35-2007",
      "type" => "standard",
      "docidentifier" => [{
        "content" => "OIML R 35:2007",
        "type" => "OIML",
        "primary" => true,
      }],
    }
  end

  describe "#write" do
    it "writes a YAML file" do
      store.write("r35_2007", valid_item)
      expect(store.exist?("r35_2007")).to be(true)
    end

    it "writes UTF-8 (accented French round-trip)" do
      store.write("r1", valid_item.merge(
        "title" => [{ "language" => "fra", "content" => "Mesures matérialisées", "type" => "main" }],
      ))
      bytes = File.read(store.path_for("r1")).encoding
      expect(bytes).to eq(Encoding::UTF_8)
    end

    it "skips when overwrite: false and file exists" do
      store.write("r1", valid_item)
      modified = valid_item.merge("id" => "X")
      expect(store.write("r1", modified, overwrite: false)).to be(false)
      expect(store.read("r1")["id"]).to eq("R35-2007")
    end

    it "overwrites by default" do
      store.write("r1", valid_item)
      store.write("r1", valid_item.merge("id" => "X-1"))
      expect(store.read("r1")["id"]).to eq("X-1")
    end

    it "accepts name with .yaml suffix" do
      store.write("r1.yaml", valid_item)
      expect(store.exist?("r1")).to be(true)
    end
  end

  describe "#write_raw" do
    it "writes a raw YAML string without Item transformation" do
      store.write_raw("notes", "---\nfoo: bar\n")
      expect(store.read("notes")).to eq({ "foo" => "bar" })
    end
  end

  describe "#read" do
    it "returns the parsed YAML" do
      store.write("r1", valid_item)
      data = store.read("r1")
      expect(data["docidentifier"].first["content"]).to eq("OIML R 35:2007")
    end
  end

  describe "#patch" do
    it "reads, yields, writes raw" do
      store.write("r1", valid_item)
      store.patch("r1") { |h| h["custom"] = "yes"; h }
      expect(store.read("r1")["custom"]).to eq("yes")
    end
  end

  describe "#exist?" do
    it "returns true for written, false for missing" do
      expect(store.exist?("missing")).to be(false)
      store.write("r1", valid_item)
      expect(store.exist?("r1")).to be(true)
    end
  end

  describe "#each_yaml" do
    it "yields (name, path) for every YAML file" do
      store.write("r1", valid_item)
      store.write("r2", valid_item.merge("id" => "X-2"))
      pairs = store.each_yaml.to_a
      expect(pairs.map(&:first)).to eq(%w[r1 r2])
    end
  end

  describe "#path_for" do
    it "resolves name to absolute path under @dir" do
      expect(store.path_for("r1")).to eq(File.join(dir, "r1.yaml"))
      expect(store.path_for("r1.yaml")).to eq(File.join(dir, "r1.yaml"))
    end
  end
end
