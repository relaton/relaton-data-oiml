# frozen_string_literal: true

require "spec_helper"
require "tmpdir"
require "yaml"

RSpec.describe OimlFetcher::Indexer do
  let(:root) { Dir.mktmpdir("oiml-indexer") }
  let(:data_dir) { File.join(root, "data") }
  let(:index_file) { File.join(root, "index-v1.yaml") }

  before { FileUtils.mkdir_p(data_dir) }

  after do
    FileUtils.rm_rf(root)
    # The relaton-index pool caches Type objects by symbol; drop it so the
    # next example starts from a clean slate.
    Relaton::Index.close(:OIML)
  end

  def write_data(name, docid)
    File.write(
      File.join(data_dir, "#{name}.yaml"),
      {
        "id" => name,
        "type" => "standard",
        "docidentifier" => [{ "content" => docid, "type" => "OIML", "primary" => true }],
      }.to_yaml,
      encoding: "UTF-8",
    )
  end

  def index_entries
    YAML.safe_load_file(index_file, permitted_classes: [Symbol])
  end

  def index_ids
    index_entries.map { |e| e[:id] }
  end

  it "indexes each data file by its primary docid" do
    write_data("r35_2007", "OIML R 35:2007")
    write_data("d1_ukr", "OIML D 1 (U)")

    described_class.build(data_dir: data_dir, index_file: index_file)

    expect(index_ids).to contain_exactly("OIML R 35:2007", "OIML D 1 (U)")
  end

  it "stores the file path relative to the index file's directory" do
    write_data("r35_2007", "OIML R 35:2007")

    described_class.build(data_dir: data_dir, index_file: index_file)

    expect(index_entries.first[:file]).to eq("data/r35_2007.yaml")
  end

  it "prunes orphan entries whose data file no longer exists" do
    # Seed an index that already contains an orphan — a stale entry left behind
    # when its data file was renamed/deleted (the real-world cause of the
    # `OIML OIML R 76 (C)` cruft).
    File.write(
      index_file,
      [
        { id: "OIML OIML R 76 (C)", file: "data/oimlr76_zho.yaml" },
        { id: "OIML R 35:2007", file: "data/r35_2007.yaml" },
      ].to_yaml,
      encoding: "UTF-8",
    )
    write_data("r35_2007", "OIML R 35:2007") # only this file exists now

    described_class.build(data_dir: data_dir, index_file: index_file)

    expect(index_ids).to contain_exactly("OIML R 35:2007")
    expect(index_ids).not_to include("OIML OIML R 76 (C)")
  end

  it "skips files without a docidentifier" do
    write_data("r35_2007", "OIML R 35:2007")
    File.write(
      File.join(data_dir, "broken.yaml"),
      { "id" => "broken", "type" => "standard" }.to_yaml,
      encoding: "UTF-8",
    )

    expect { described_class.build(data_dir: data_dir, index_file: index_file) }
      .to output(/broken\.yaml/).to_stderr

    expect(index_ids).to contain_exactly("OIML R 35:2007")
  end
end
