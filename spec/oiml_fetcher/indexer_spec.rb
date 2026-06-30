# frozen_string_literal: true

require "spec_helper"
require "tmpdir"
require "yaml"
require "pubid" # the structured-index examples reference Pubid in their setup

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

  describe "structured index-v2.yaml (pubid)" do
    let(:index_v2_file) { File.join(root, "index-v2.yaml") }

    def v2_entries
      # Drop the pooled Type so this reads + deserializes from disk (exercising
      # pubid from_hash) rather than returning build's in-memory objects.
      Relaton::Index.close(:OIML)
      Relaton::Index.find_or_create(
        :OIML, file: index_v2_file, pubid_class: Pubid::Oiml::Identifier
      ).index
    end

    it "writes structured pubid ids that deserialize back to Pubid::Oiml" do
      write_data("r35_2007", "OIML R 35:2007")
      write_data("b18_c", "OIML B 18 (C)") # custom language code

      described_class.build(
        data_dir: data_dir, index_file: index_file, index_v2_file: index_v2_file,
      )

      ids = v2_entries.map { |e| e[:id] }
      expect(ids).to all(be_a(Pubid::Oiml::Identifier))
      expect(ids.map(&:to_s)).to contain_exactly("OIML R 35:2007", "OIML B 18 (C)")
    end

    it "keeps the v1 string index in step with the v2 structured index" do
      write_data("r35_2007", "OIML R 35:2007")

      described_class.build(
        data_dir: data_dir, index_file: index_file, index_v2_file: index_v2_file,
      )

      expect(index_ids).to contain_exactly("OIML R 35:2007")
      expect(v2_entries.size).to eq(1)
    end

    it "prunes orphans from the structured index too" do
      # Seed a v2 index already holding a (valid-but-stale) entry whose file is gone.
      stale = Pubid::Oiml.parse("OIML R 99:1999")
      File.write(
        index_v2_file,
        [{ id: stale.to_hash, file: "data/r99_1999.yaml" }].to_yaml,
        encoding: "UTF-8",
      )
      write_data("r35_2007", "OIML R 35:2007") # only this file exists now

      described_class.build(
        data_dir: data_dir, index_file: index_file, index_v2_file: index_v2_file,
      )

      expect(v2_entries.map { |e| e[:id].to_s }).to contain_exactly("OIML R 35:2007")
    end

    it "leaves the v1 index untouched when no v2 file is requested" do
      write_data("r35_2007", "OIML R 35:2007")

      described_class.build(data_dir: data_dir, index_file: index_file)

      expect(File.exist?(index_v2_file)).to be(false)
    end
  end
end
