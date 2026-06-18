#!/usr/bin/env ruby
# frozen_string_literal: true

# Crawler entry point. The relaton/support daily workflow runs
# `bundle exec ruby crawler.rb`. Reads every data/*.yaml, parses with
# relaton-bib, and writes a flat string index (docid → relative file path)
# to index-v1.yaml using relaton-index.

require "relaton/index"
require "relaton/bib"
require "yaml"

DATA_DIR = File.join(__dir__, "data")
INDEX_FILE = File.join(__dir__, "index-v1.yaml")

idx = Relaton::Index.find_or_create :OIML, file: INDEX_FILE

Dir[File.join(DATA_DIR, "*.yaml")].sort.each do |f|
  item = Relaton::Bib::Item.from_yaml(File.read(f, encoding: "UTF-8"))
  docid = item.docidentifier.find(&:primary) || item.docidentifier.first
  unless docid
    warn "Error processing #{f}: no docidentifier"
    next
  end
  idx.add_or_update docid.content, f.sub("#{__dir__}/", "")
rescue StandardError => e
  warn "Error processing #{f}: #{e.message}"
end

idx.save
puts "Wrote #{INDEX_FILE} (#{idx.index.size} entries)"
