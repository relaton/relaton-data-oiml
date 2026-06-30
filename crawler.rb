#!/usr/bin/env ruby
# frozen_string_literal: true

# Crawler entry point. The relaton/support daily workflow runs
# `bundle exec ruby crawler.rb`. Rebuilds the indexes (docid → relative file
# path) over every data/*.yaml via OimlFetcher::Indexer, which mirrors the
# data/ directory exactly on each run (no orphan entries left behind):
#   index-v1.yaml — flat string docid index
#   index-v2.yaml — structured pubid identifier index (pubid v2 OIML)

$LOAD_PATH.unshift File.expand_path("lib", __dir__)
require "oiml_fetcher"

idx_v1, idx_v2 = OimlFetcher::Indexer.build(
  data_dir: File.join(__dir__, "data"),
  index_file: File.join(__dir__, "index-v1.yaml"),
  index_v2_file: File.join(__dir__, "index-v2.yaml"),
)
puts "Wrote index-v1.yaml (#{idx_v1.index.size} entries)"
puts "Wrote index-v2.yaml (#{idx_v2.index.size} entries)"
