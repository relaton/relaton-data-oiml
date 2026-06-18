#!/usr/bin/env ruby
# frozen_string_literal: true

# Round-trip validator: load each data/*.yaml through relaton-bib, re-serialize,
# and diff against the source. Exit 1 on any mismatch or missing primary
# docidentifier.

require "relaton/bib"
require "yaml"

path = ARGV.first || "data/*.{yaml,yml}"

errors = false
Dir[path].sort.each do |f|
  yaml = File.read(f, encoding: "UTF-8")
  item = Relaton::Bib::Item.from_yaml(yaml)

  primary_id = item.docidentifier.find(&:primary)
  unless primary_id
    errors = true
    puts "Parsing #{f} failed. No primary docidentifier."
    next
  end

  reserialized = item.to_yaml
  next if reserialized == yaml

  errors = true
  puts "Round-trip mismatch in #{f}:"
  src_lines = yaml.split("\n")
  out_lines = reserialized.split("\n")
  require "diff/lcs"
  Diff::LCS.sdiff(src_lines, out_lines).each do |change|
    next if change.action == "="

    case change.action
    when "-" then puts "  - #{change.old_element}"
    when "+" then puts "  + #{change.new_element}"
    when "!" then puts "  - #{change.old_element}\n  + #{change.new_element}"
    end
  end
  puts
rescue StandardError => e
  errors = true
  puts "Parsing #{f} failed: #{e.message}"
  puts e.backtrace.first(5)
  puts
end

exit(1) if errors
puts "OK: all data files round-trip cleanly."
