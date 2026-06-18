# frozen_string_literal: true

require "spec_helper"

RSpec.describe OimlFetcher::Docid do
  describe ".from_short_title" do
    it "parses prefix, number, year" do
      d = described_class.from_short_title("R 35:2007(en)")
      expect(d.prefix).to eq("R")
      expect(d.number).to eq(35)
      expect(d.year).to eq(2007)
      expect(d.parts).to be_nil
    end

    it "parses parts from short_title with part number" do
      d = described_class.from_short_title("B 6-1:2023(en)")
      expect(d.parts).to eq([1])
    end

    it "parses combined parts" do
      d = described_class.from_short_title("R 46-1-2:2012(en)")
      expect(d.parts).to eq([1, 2])
    end

    it "strips (E) and (F) variants" do
      d = described_class.from_short_title("R 35:2007(E)")
      expect(d.number).to eq(35)
    end

    it "raises on garbage input" do
      expect { described_class.from_short_title("not-a-docid") }
        .to raise_error(ArgumentError, /Unrecognized docid format/)
    end
  end

  describe ".from_translation_ref" do
    it "parses a clean ref" do
      d = described_class.from_translation_ref("R 35-1:2007")
      expect(d.prefix).to eq("R")
      expect(d.number).to eq(35)
      expect(d.parts).to eq([1])
      expect(d.year).to eq(2007)
    end

    it "parses ref without year" do
      d = described_class.from_translation_ref("R 7")
      expect(d.year).to be_nil
    end
  end

  describe ".from_pdf_filename" do
    it "parses a basic part filename" do
      d = described_class.from_pdf_filename("R035-1-e07.pdf")
      expect(d.prefix).to eq("R")
      expect(d.number).to eq(35)
      expect(d.parts).to eq([1])
      expect(d.year).to eq(2007)
      expect(d.lang).to eq("eng")
    end

    it "parses a French filename" do
      d = described_class.from_pdf_filename("R035-1-f07.pdf")
      expect(d.lang).to eq("fra")
    end

    it "parses an amendment" do
      d = described_class.from_pdf_filename("R035-1_amend-e14.pdf")
      expect(d.suffix_type).to eq(:amendment)
      expect(d.year).to eq(2014)
      expect(d.parts).to eq([1])
    end

    it "parses an annex" do
      d = described_class.from_pdf_filename("R102-Ann-B-C-e95.pdf")
      expect(d.suffix_type).to eq(:annex)
      expect(d.annex_letter).to eq("B-C")
      expect(d.year).to eq(1995)
    end

    it "parses annexes (plural)" do
      d = described_class.from_pdf_filename("R060-Annexes-e17.pdf")
      expect(d.suffix_type).to eq(:annexes)
    end

    it "parses errata with embedded original year" do
      d = described_class.from_pdf_filename("R126-e12-errata-e15.pdf")
      expect(d.suffix_type).to eq(:errata)
      expect(d.year).to eq(2015)
      expect(d.original_year).to eq(2012)
    end

    it "parses erratum" do
      d = described_class.from_pdf_filename("R051-1-erratum-e10.pdf")
      expect(d.suffix_type).to eq(:errata)
      expect(d.parts).to eq([1])
      expect(d.year).to eq(2010)
    end

    it "parses reconfirmed" do
      d = described_class.from_pdf_filename("R107-1-e07-reconfirmed-2024.pdf")
      expect(d.reconfirmed_year).to eq(2024)
      expect(d.parts).to eq([1])
      expect(d.year).to eq(2007)
    end

    it "parses combined parts" do
      d = described_class.from_pdf_filename("R046-1-2-e12.pdf")
      expect(d.parts).to eq([1, 2])
    end

    it "parses an amendment with a full date" do
      d = described_class.from_pdf_filename("R060-amendment-2019-12-23.pdf")
      expect(d.year).to eq(2019)
    end

    it "returns nil on garbage" do
      expect(described_class.from_pdf_filename("garbage.pdf")).to be_nil
    end
  end

  describe "#to_s" do
    it "renders work docid" do
      expect(described_class.from_short_title("R 35:2007(en)").to_s)
        .to eq("OIML R 35:2007")
    end

    it "renders part docid" do
      expect(described_class.from_translation_ref("R 35-1:2007").to_s)
        .to eq("OIML R 35-1:2007")
    end
  end

  describe "#id" do
    it "strips OIML prefix and slugifies" do
      expect(described_class.from_short_title("R 35:2007(en)").id)
        .to eq("R35-2007")
    end

    it "handles multi-part" do
      expect(described_class.from_translation_ref("R 35-1:2007").id)
        .to eq("R35-1-2007")
    end
  end

  describe "#filename_stem" do
    it "lowercases the id" do
      expect(described_class.from_short_title("R 35:2007(en)").filename_stem)
        .to eq("r35-2007")
    end
  end

  describe "#with_lang" do
    it "appends OIML letter code" do
      d = described_class.from_short_title("R 35:2007(en)")
      expect(d.with_lang("eng")).to eq("OIML R 35:2007 (E)")
      expect(d.with_lang("fra")).to eq("OIML R 35:2007 (F)")
    end

    it "raises on unknown lang" do
      d = described_class.from_short_title("R 35:2007(en)")
      expect { d.with_lang("xxx") }.to raise_error(KeyError)
    end
  end

  describe "#with_suffix" do
    it "produces a new docid with the suffix" do
      base = described_class.from_translation_ref("R 35-1:2007")
      amended = base.with_suffix(:amendment, year: 2014)
      expect(amended.suffix_type).to eq(:amendment)
      expect(amended.year).to eq(2014)
    end
  end

  describe "immutability" do
    it "is frozen" do
      expect(described_class.from_short_title("R 35:2007(en)")).to be_frozen
    end
  end
end
