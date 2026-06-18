# frozen_string_literal: true

require "net/http"
require "json"
require "fileutils"
require "time"
require "uri"
require "yaml"

require "relaton/bib"
require "nokogiri"
require "active_support/core_ext/string/filters"

# OimlFetcher scrapes oiml.org publications and translation pages into
# Relaton YAML files under data/.
module OimlFetcher
  BASE_URL = "https://www.oiml.org".freeze

  TYPES = {
    "recommendations" => [1, "R", "recommandations",  "recommendation"],
    "documents"       => [2, "D", "documents",        "document"],
    "guides"          => [3, "G", "guides",           "guide"],
    "vocabularies"    => [4, "V", "vocabulaires",     "vocabulary"],
    "basic"           => [6, "B", "publications-base", "basic-publication"],
    "expert"          => [7, "E", "rapports-dexpert",  "expert-report"],
    "seminar"         => [8, "S", "seminaire",         "seminar-report"],
  }.freeze

  # idStatus 0 and 7 are not in the JS bundle; discovered by probing the API.
  # 0 appears on some seminar entries with no explicit status; treat as in-force.
  # 2 is FR-endpoint-only marker for in-force French editions.
  # 7 marks joint publications hosted elsewhere (e.g. R 99-ISO3930).
  STATUS_NAMES = {
    0 => "in-force",
    1 => "in-force",
    2 => "in-force",
    5 => "superseded",
    6 => "withdrawn",
    7 => "joint",
  }.freeze

  ALL_STATUSES = [1, 5, 6].freeze

  OIML_NAME = "International Organization of Legal Metrology".freeze
  OIML_ABBR = "OIML".freeze

  TRANSLATION_LANGS = %w[
    arabic chinese german persian polish portuguese
    russian serbian spanish ukrainian
  ].freeze

  LANG_CODE = {
    "arabic"     => "ara",
    "chinese"    => "zho",
    "german"     => "deu",
    "persian"    => "fas",
    "polish"     => "pol",
    "portuguese" => "por",
    "russian"    => "rus",
    "serbian"    => "srp",
    "spanish"    => "spa",
    "ukrainian"  => "ukr",
  }.freeze

  DOCID_LANG_CODE = {
    "eng" => "E",
    "fra" => "F",
    "deu" => "D",
    "rus" => "R",
    "spa" => "S",
    "zho" => "C",
    "ara" => "A",
    "ukr" => "U",
    "pol" => "PO",
    "por" => "PT",
    "fas" => "PE",
    "srp" => "SR",
  }.freeze

  def self.oiml_org_hash
    {
      "name" => [{ "content" => OIML_NAME }],
      "abbreviation" => { "content" => OIML_ABBR },
    }
  end

  def self.oiml_publisher_contributor
    {
      "role" => [{ "type" => "publisher" }],
      "organization" => oiml_org_hash,
    }
  end

  autoload :Docid,           "oiml_fetcher/docid"
  autoload :Source,          "oiml_fetcher/source"
  autoload :Http,            "oiml_fetcher/http"
  autoload :YamlStore,       "oiml_fetcher/yaml_store"
  autoload :FilenameParser,  "oiml_fetcher/filename_parser"
  autoload :PublicationFetcher, "oiml_fetcher/publication_fetcher"
  autoload :TranslationFetcher, "oiml_fetcher/translation_fetcher"
  autoload :PortfolioFetcher,   "oiml_fetcher/portfolio_fetcher"
  autoload :PartsBuilder,       "oiml_fetcher/parts_builder"
  autoload :Caco3Fetcher,       "oiml_fetcher/caco3_fetcher"
  autoload :Scrape,             "oiml_fetcher/scrape"
end
