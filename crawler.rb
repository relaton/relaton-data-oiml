#!/usr/bin/env ruby
# frozen_string_literal: true

# Crawler entry point. The relaton/support daily workflow runs
# `bundle exec ruby crawler.rb`. Rebuilds index-v1.yaml (docid → relative file
# path) over every data/*.yaml via OimlFetcher::Indexer, which mirrors the
# data/ directory exactly on each run (no orphan entries left behind).

$LOAD_PATH.unshift File.expand_path("lib", __dir__)
require "oiml_fetcher"

idx = OimlFetcher::Indexer.build(
  data_dir: File.join(__dir__, "data"),
  index_file: File.join(__dir__, "index-v1.yaml"),
)
puts "Wrote index-v1.yaml (#{idx.index.size} entries)"
