# frozen_string_literal: true

require "spec_helper"

RSpec.describe OimlFetcher::FilenameParser do
  it "delegates to Docid.from_pdf_filename" do
    result = described_class.parse("R035-1-e07.pdf")
    expect(result).to be_a(OimlFetcher::Docid)
    expect(result.number).to eq(35)
    expect(result.parts).to eq([1])
    expect(result.year).to eq(2007)
    expect(result.lang).to eq("eng")
  end

  it "returns nil for garbage" do
    expect(described_class.parse("not-a-real-file.pdf")).to be_nil
  end

  it "handles every real-world filename shape we've seen" do
    samples = {
      "R100-1-e13.pdf"         => { prefix: "R", number: 100, parts: [1], year: 2013, lang: "eng" },
      "R102-Ann-B-C-e95.pdf"   => { prefix: "R", number: 102, suffix_type: :annex, annex_letter: "B-C", year: 1995 },
      "R035-1_amend-e14.pdf"   => { prefix: "R", number: 35, parts: [1], suffix_type: :amendment, year: 2014 },
      "R126-e12-errata-e15.pdf" => { prefix: "R", number: 126, suffix_type: :errata, year: 2015, original_year: 2012 },
      "R107-1-e07-reconfirmed-2024.pdf" => { prefix: "R", number: 107, parts: [1], year: 2007, reconfirmed_year: 2024 },
      "R046-1-2-e12.pdf"       => { prefix: "R", number: 46, parts: [1, 2], year: 2012 },
      "R060-Annexes-e17.pdf"   => { prefix: "R", number: 60, suffix_type: :annexes, year: 2017 },
    }
    samples.each do |filename, expected|
      got = described_class.parse(filename)
      aggregate_failures filename do
        expected.each { |k, v| expect(got.public_send(k)).to eq(v), "#{k} mismatch on #{filename}" }
      end
    end
  end
end
