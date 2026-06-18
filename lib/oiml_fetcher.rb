# frozen_string_literal: true

require "net/http"
require "json"
require "fileutils"
require "time"

require "relaton/bib"
require "nokogiri"
require "active_support/core_ext/string/filters" # String#squish

# OimlFetcher scrapes oiml.org publications and translation pages into
# Relaton YAML files under data/.
module OimlFetcher
  BASE_URL = "https://www.oiml.org".freeze

  # path segment (EN) → (p_type, prefix, FR segment, doctype label)
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

  # idStatus values that should be fetched. 2/3/4 return empty.
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
end

require_relative "oiml_fetcher/scrape"
require_relative "oiml_fetcher/publication_fetcher"
require_relative "oiml_fetcher/translation_fetcher"
require_relative "oiml_fetcher/portfolio_fetcher"
require_relative "oiml_fetcher/parts_builder"
