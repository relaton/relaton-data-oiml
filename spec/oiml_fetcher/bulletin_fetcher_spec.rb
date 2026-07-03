# frozen_string_literal: true

require "spec_helper"
require "tmpdir"

RSpec.describe OimlFetcher::BulletinFetcher do
  let(:dir) { Dir.mktmpdir("oiml-bulletin") }
  let(:store) { OimlFetcher::YamlStore.new(dir) }
  after { FileUtils.rm_rf(dir) }

  # Mimics the real article DOM: .bulletin-header-left with h1 title, h2
  # subtitle, <p><strong>Author</strong>, <p>Affiliation, <h6>Citation:...,
  # followed by .bulletin-body with the abstract paragraph.
  ARTICLE_HTML = <<~HTML.freeze
    <html><body>
      <div id="content-core">
        <div class="row"><div class="col-md-6 bulletin-header-left">
          <h5>OIML BULLETIN - <a href="https://www.oiml.org/en/publications/oiml-bulletin/2026-02" text="2026 - VOLUME LXVII - NUMBER 2">2026 - VOLUME LXVII - NUMBER 2</a></h5>
          <h1>The digital tachograph</h1>
          <h2>An alternative analysis of the uncertainty of the calibration process</h2>
          <p><strong>Giuseppe Ardimento</strong></p>
          <p>Head of Market Regulation, Naples Chamber of Commerce, Italy</p>
          <h6>Citation: G. Ardimento 2026 OIML Bulletin LXVII(2) 20260211</h6>
        </div></div>
        <div class="row"><div class="col-xs-12 bulletin-body">
          <h2>Introduction</h2>
          <p>The digital tachograph is an electronic device installed in commercial vehicles.</p>
        </div></div>
      </div>
    </body></html>
  HTML

  FOREWORD_HTML = <<~HTML.freeze
    <html><body>
      <div id="content-core"><div class="row"><div class="col-md-6 bulletin-header-left">
        <h5>OIML BULLETIN - <a href="https://www.oiml.org/en/publications/oiml-bulletin/2026-02" text="2026 - VOLUME LXVII - NUMBER 2">2026 - VOLUME LXVII - NUMBER 2</a></h5>
        <h1>Supporting Climate Action and Sustainability</h1>
        <h2>Foreword</h2>
        <h6>Citation: Guest Editor 2026 OIML Bulletin LXVII(2) 20260200</h6>
      </div></div>
      <div class="row"><div class="col-xs-12 bulletin-body">
        <p>A guest-edited special edition focused on climate action.</p>
      </div></div></div>
    </body></html>
  HTML

  ISSUE_HTML = <<~HTML.freeze
    <html><body>
      <h5>OIML BULLETIN - <a href="https://www.oiml.org/en/publications/oiml-bulletin/2026-02" text="2026 - VOLUME LXVII - NUMBER 2">2026 - VOLUME LXVII - NUMBER 2</a></h5>
      <a href="https://www.oiml.org/en/publications/oiml-bulletin/2026-02/20260200">Foreword</a>
      <a href="https://www.oiml.org/en/publications/oiml-bulletin/2026-02/20260211">The digital tachograph</a>
    </body></html>
  HTML

  ISSUE_2026_01_HTML = <<~HTML.freeze
    <html><body>
      <h5>OIML BULLETIN - <a href="https://www.oiml.org/en/publications/oiml-bulletin/2026-01" text="2026 - VOLUME LXVII - NUMBER 1">2026 - VOLUME LXVII - NUMBER 1</a></h5>
      <a href="https://www.oiml.org/en/publications/oiml-bulletin/2026-01/20260100">Foreword</a>
    </body></html>
  HTML

  LISTING_HTML = <<~HTML.freeze
    <html><body>
      <a href="https://www.oiml.org/en/publications/oiml-bulletin/2026-01/20260100">Foreword</a>
      <a href="https://www.oiml.org/en/publications/oiml-bulletin/pdf/oiml_bulletin_jan_2024.pdf">2024-01</a>
      <a href="https://www.oiml.org/en/publications/oiml-bulletin/2026-02/20260211">Tachograph</a>
    </body></html>
  HTML

  let(:fake_http) do
    OimlFetcher::Http::Fake.new(
      "https://www.oiml.org/en/publications/oiml-bulletin/2026-01" => ISSUE_2026_01_HTML,
      "https://www.oiml.org/en/publications/oiml-bulletin/2026-01/20260100" => FOREWORD_HTML,
      "https://www.oiml.org/en/publications/oiml-bulletin/2026-02" => ISSUE_HTML,
      "https://www.oiml.org/en/publications/oiml-bulletin/2026-02/20260200" => FOREWORD_HTML,
      "https://www.oiml.org/en/publications/oiml-bulletin/2026-02/20260211" => ARTICLE_HTML,
      "https://www.oiml.org/en/publications/oiml-bulletin/online-bulletin" => LISTING_HTML,
    )
  end

  def fetcher = described_class.new(yaml_store: store, http_backend: fake_http)

  it "auto-enumerates only HTML issue slugs from the listing (no PDFs)" do
    expect(fetcher.enumerate_html_issues).to eq(
      [{ "slug" => "2026-01", "prefix" => "" },
       { "slug" => "2026-02", "prefix" => "" }]
    )
  end

  it "auto-enumerates issues under the /online-bulletin-1/ subpath too" do
    listing = <<~HTML
      <html><body>
        <a href="https://www.oiml.org/en/publications/oiml-bulletin/2025-02/20250201">Article</a>
        <a href="https://www.oiml.org/en/publications/oiml-bulletin/online-bulletin-1/2024-07/20240701">Article</a>
        <a href="https://www.oiml.org/en/publications/oiml-bulletin/online-bulletin-1/2024-10/20241001">Article</a>
      </body></html>
    HTML
    http = OimlFetcher::Http::Fake.new(
      "https://www.oiml.org/en/publications/oiml-bulletin/online-bulletin" => listing,
    )
    f = described_class.new(yaml_store: store, http_backend: http)
    expect(f.enumerate_html_issues).to contain_exactly(
      { "slug" => "2024-07", "prefix" => "online-bulletin-1/" },
      { "slug" => "2024-10", "prefix" => "online-bulletin-1/" },
      { "slug" => "2025-02", "prefix" => "" }
    )
  end

  it "emits bulletin, volume, issue, and article records for a processed issue" do
    fetcher.run(issues: ["2026-02"])

    expect(store.exist?("bulletin")).to be(true)
    expect(store.exist?("bulletin_2026")).to be(true)
    expect(store.exist?("bulletin_2026-02")).to be(true)
    expect(store.exist?("bulletin_2026-02-00")).to be(true)
    expect(store.exist?("bulletin_2026-02-11")).to be(true)
  end

  it "writes the article with title, subtitle, author, affiliation, and citation-derived extent" do
    fetcher.run(issues: ["2026-02"])

    art = store.read("bulletin_2026-02-11")
    expect(art["type"]).to eq("article")
    expect(art["title"].map { |t| t["type"] }).to contain_exactly("main", "subtitle")
    expect(art["title"].find { |t| t["type"] == "main" }["content"]).to eq("The digital tachograph")

    author = art["contributor"].find { |c| c["role"].first["type"] == "author" }
    expect(author["person"]["name"]["completename"]["content"]).to eq("Giuseppe Ardimento")
    expect(author["person"]["affiliation"].first["organization"]["name"].first["content"])
      .to eq("Head of Market Regulation, Naples Chamber of Commerce, Italy")

    primary = art["docidentifier"].find { |d| d["primary"] }
    expect(primary["content"]).to eq("OIML Bulletin 2026-02-11")
    localities = art["extent"].first["locality"]
    expect(localities.find { |l| l["type"] == "volume" }["reference_from"]).to eq("LXVII")
    expect(localities.find { |l| l["type"] == "issue" }["reference_from"]).to eq("2")

    expect(art["series"].first["title"].first["content"]).to eq("OIML Bulletin")
    expect(art["relation"].first["type"]).to eq("includedIn")
  end

  it "records the publisher (no author) when the article has no author byline" do
    fetcher.run(issues: ["2026-02"])

    foreword = store.read("bulletin_2026-02-00")
    expect(foreword["contributor"].map { |c| c["role"].first["type"] }).to eq(["publisher"])
    expect(foreword["title"].find { |t| t["type"] == "subtitle" }["content"]).to eq("Foreword")
  end

  it "builds bidirectional containment relations across the four tiers" do
    fetcher.run(issues: ["2026-02"])

    issue = store.read("bulletin_2026-02")
    issue_targets = issue["relation"].select { |r| r["type"] == "hasPart" }
                                      .map { |r| r["bibitem"]["docidentifier"].first["content"] }
    expect(issue_targets).to contain_exactly("OIML Bulletin 2026-02-00", "OIML Bulletin 2026-02-11")
    expect(issue["relation"].find { |r| r["type"] == "partOf" }["bibitem"]["docidentifier"]
      .first["content"]).to eq("OIML Bulletin 2026")

    volume = store.read("bulletin_2026")
    volume_targets = volume["relation"].select { |r| r["type"] == "hasPart" }
                                        .map { |r| r["bibitem"]["docidentifier"].first["content"] }
    expect(volume_targets).to include("OIML Bulletin 2026-02")
    expect(volume["relation"].find { |r| r["type"] == "partOf" }["bibitem"]["docidentifier"]
      .first["content"]).to eq("OIML Bulletin")

    bulletin = store.read("bulletin")
    bulletin_targets = bulletin["relation"].select { |r| r["type"] == "hasPart" }
                                           .map { |r| r["bibitem"]["docidentifier"].first["content"] }
    expect(bulletin_targets).to eq(["OIML Bulletin 2026"])
  end

  it "publishes quarterly issues to the right month (issue 2 -> April)" do
    fetcher.run(issues: ["2026-02"])
    expect(store.read("bulletin_2026-02-11")["date"].first["from"]).to eq("2026-04-01")
  end

  it "derives the volume roman numeral from the issue page header link" do
    fetcher.run(issues: ["2026-02"])
    expect(store.read("bulletin_2026")["extent"].first["locality"]
      .first["reference_from"]).to eq("LXVII")
  end

  it "auto-enumerates and processes every HTML issue when no issues are passed" do
    fetcher.run
    expect(store.exist?("bulletin_2026-01")).to be(true)
    expect(store.exist?("bulletin_2026-02")).to be(true)
    # Volume aggregates both issues as hasPart children.
    volume_targets = store.read("bulletin_2026")["relation"]
      .select { |r| r["type"] == "hasPart" }
      .map { |r| r["bibitem"]["docidentifier"].first["content"] }
    expect(volume_targets).to contain_exactly("OIML Bulletin 2026-01", "OIML Bulletin 2026-02")
  end
end
