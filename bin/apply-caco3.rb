#!/usr/bin/env ruby
# frozen_string_literal: true

# Apply the caco3 extract's reconciled updates to data/*.yaml.
# Surgical text edits only — the canonical serialization is never rewritten.
#
#   1. Status corrections (work/edition/part level) — each flip asserts the
#      current value, so a drift in the data fails loudly instead of
#      double-flipping.
#   2. ext.doi set from the Crossref-registered set (10.63493): replaces
#      mis-keyed values (the spider stamped the EN DOI on FR instances)
#      and inserts missing ones.
#   3. ext.oimlcs on every ext-bearing record of the works the extract
#      flags as OIML-CS applicable.
#
# Usage: ruby bin/apply-caco3.rb /path/to/files   # dir containing csv/

require "csv"

SRC = ARGV[0] or abort "usage: apply-caco3.rb <extract-dir>"
CSV_DIR = File.join(SRC, "csv")
DATA = File.expand_path("data", __dir__ + "/..")

def norm(s) = s.to_s.gsub(/\s+/, " ").strip

# ── 1. Status corrections ─────────────────────────────────────────────
# from the reconciliation (§2 work-level, §3 edition-level, §4 part-level).
# Skipped with reasons (see the PR): V 2 (their work-current reflects VIM
# editions this dataset does not carry), G 1 (their G 1 is the withdrawn
# original Guide; our records are the G 1-1xx successor series),
# R 142:2008 (their row is stale — our 2025 editions supersede it).

SUPERSEDED = %w[
  d10_2022* b4_1996* b5_1996*
  r49-1-2000* r49-1-2013*
  r60-1-2017* r60-2-2017* r60-3-2017* r60-4-2017*
  r76-1-1994* r117-1-2007* r139-1-2014*
].freeze
WITHDRAWN = %w[r16-1-2002* r16-2-2002*].freeze
IN_FORCE  = %w[b7_2013*].freeze

changed = Hash.new(0)
flipped = []

def files_for(glob) = Dir[File.join(DATA, glob + "{.yaml,.yml}")].sort

def flip_status(path, to, changed, flipped)
  text = File.read(path, encoding: "UTF-8")
  m = text.match(/status:\n  stage:\n    content: (\S[^\n]*)\n/)
  abort "no status block in #{File.basename(path)}" unless m
  current = norm(m[1])
  return if current == to

  # joint (B 4/B 5: co-published ISO/OIML documents) and in-force are the
  # only legitimate origins for these flips
  ok_from = to == "in-force" ? ["superseded"] : ["in-force", "joint"]
  abort "#{File.basename(path)}: expected #{ok_from.join('/')}, found #{current}" unless ok_from.include?(current)
  File.write(path, text.sub(/status:\n  stage:\n    content: (\S[^\n]*)\n/, "status:\n  stage:\n    content: #{to}\n"))
  changed[File.basename(path)] += 1
  flipped << "#{File.basename(path)}: #{current} -> #{to}"
end

# Language instances inherit their base record's status. The extract's
# per-edition status agrees with our base records; the instances lagged.
LANGS = %w[eng fra ara fas spa deu rus pol por zho ukr srp ron].freeze
synced = []
base_files = Dir[File.join(DATA, "*.yaml")].map { |p| File.basename(p, ".yaml") }
status_of = lambda do |name|
  path = File.join(DATA, name + ".yaml")
  t = File.read(path, encoding: "UTF-8")
  t[/status:\n  stage:\n    content: (\S[^\n]*)\n/, 1]
end

# instance file → its base record: same stem minus the language suffix;
# dash/underscore stems are interchangeable (dash-named translation
# variants pair with the underscore-indexed base)
base_for = lambda do |inst|
  stem = inst.sub(/_(#{LANGS.join('|')})$/, "")
  return stem if base_files.include?(stem)
  twin = stem.tr("-", "_")
  stem = twin if base_files.include?(twin)
  stem
end

LANGS.each do |lang|
  Dir[File.join(DATA, "*_#{lang}.yaml")].sort.each do |inst_path|
    inst = File.basename(inst_path, ".yaml")
    stem = base_for.call(inst)
    next unless stem && base_files.include?(stem)
    st = status_of.call(stem)
    ist = status_of.call(inst)
    next unless st && ist && norm(ist) != norm(st)
    itext = File.read(inst_path, encoding: "UTF-8")
    File.write(inst_path, itext.sub(/status:\n  stage:\n    content: \S[^\n]*\n/, "status:\n  stage:\n    content: #{norm(st)}\n"))
    changed[inst] += 1
    synced << "#{inst}: #{norm(ist)} -> #{norm(st)}"
  end
end

SUPERSEDED.each { |g| files_for(g).each { |f| flip_status(f, "superseded", changed, flipped) } }
WITHDRAWN.each { |g| files_for(g).each { |f| flip_status(f, "withdrawn", changed, flipped) } }
IN_FORCE.each { |g| files_for(g).each { |f| flip_status(f, "in-force", changed, flipped) } }

# ── 2. ext.doi from the registered Crossref set ───────────────────────

SUFFIX = /\A([a-z])(\d{3})(?:-(\d+(?:-\d+)*))?(?:\.(\d{4}))?(?:\.(en|fr))?\z/.freeze
ID_RE  = /\AOIML ([A-Z])\s*-?\s*(\d+)(?:-(\d+(?:-\d+)*))?(?::(\d{4}))?(.*)\z/m.freeze
LANG_MARK = /\(([A-Za-z]{1,3}(?:\/[A-Za-z]{1,3})*)\)\s*\z/.freeze

records = {}
Dir[File.join(DATA, "*.yaml")].sort.each do |f|
  base = File.basename(f, ".yaml")
  next if base.start_with?("bulletin_")
  primary_line = File.read(f, encoding: "UTF-8")[/^docidentifier:\n- content: (OIML [^\n]+)\n/, 1]
  next unless primary_line
  m = primary_line.match(ID_RE)
  next unless m
  tail = m[5].to_s
  lm = tail.match(LANG_MARK)
  marker = lm && lm[1].to_s.split("/").map(&:downcase).first
  lang = { "e" => "en", "f" => "fr", "en" => "en", "fr" => "fr" }[marker]
  # filename suffix is authoritative for instance files (dash or underscore)
  fsfx = base[/_(eng|fra)$/, 1]
  lang = { "eng" => "en", "fra" => "fr" }[fsfx] if fsfx
  next if tail =~ /annex|amendment/i
  records[[m[1].downcase, m[2].to_i, m[3], m[4]&.to_i, lang]] = base
end

exact = {}
base_rec = {}
records.each do |(l, n, part, year, lang), f|
  if lang
    exact[[l, n, part, year, lang]] = f
  else
    base_rec[[l, n, part, year]] = f
  end
end

doi_set = {}
CSV.read(File.join(CSV_DIR, "crossref_dois.csv"), headers: true).each do |r|
  s = r["doi"].sub(/\A10\.63493\//, "")
  m = s.match(SUFFIX)
  next unless m && m[4] # edition/part-level only

  key = [m[1], m[2].to_i, m[3], m[4].to_i]
  target = exact[key + [m[5]]]
  if target.nil? && exact.none? { |(l, n, pt, yr, lg), _| l == m[1] && n == m[2].to_i && pt == m[3] && yr == m[4].to_i && lg }
    # no language instance for this edition at all → the base record carries it
    target = base_rec[key]
  end
  doi_set[target] = r["doi"] if target
end

doi_replaced = doi_added = 0
doi_set.each do |base, doi|
  path = File.join(DATA, base + ".yaml")
  text = File.read(path, encoding: "UTF-8")
  if (line = text[/^  doi: (\S+)\n/])
    next if line.strip == "doi: #{doi}"
    text = text.sub(/^  doi: (\S+)\n/, "  doi: #{doi}\n")
    doi_replaced += 1
  elsif text.include?("\next:\n")
    text = text.sub("\next:\n", "\next:\n  doi: #{doi}\n")
    doi_added += 1
  else
    warn "  no ext block for doi insert: #{base}"
    next
  end
  File.write(path, text)
  changed[base] += 1
end

# ── 3. ext.oimlcs ─────────────────────────────────────────────────────

types = CSV.read(File.join(CSV_DIR, "types.csv"), headers: true).to_h { |r| [r["id"].to_i, r] }
oimlcs_works = {}
CSV.read(File.join(CSV_DIR, "publications.csv"), headers: true).each do |p|
  next unless p["oimlcs"] == "yes"
  letter = p["typefk"].to_i == 8 ? "s" : types[p["typefk"].to_i]["letter"].downcase
  oimlcs_works[[letter, p["number"].to_i]] = true
end

oimlcs_files = 0
Dir[File.join(DATA, "*.yaml")].sort.each do |f|
  base = File.basename(f, ".yaml")
  next if base.start_with?("bulletin_")
  primary_line = File.read(f, encoding: "UTF-8")[/^docidentifier:\n- content: (OIML [^\n]+)\n/, 1]
  m = primary_line&.match(ID_RE)
  next unless m && oimlcs_works[[m[1].downcase, m[2].to_i]]
  text = File.read(f, encoding: "UTF-8")
  next unless text.include?("\next:\n")
  next if text.include?("  oimlcs:")
  File.write(f, text.sub("\next:\n", "\next:\n  oimlcs: true\n"))
  oimlcs_files += 1
  changed[base] += 1
end

# ── report ────────────────────────────────────────────────────────────

puts "instance-status syncs: #{synced.size}"
synced.each { |x| puts "  #{x}" }
puts "status flips: #{flipped.size}"
flipped.each { |x| puts "  #{x}" }
puts "doi: replaced #{doi_replaced}, added #{doi_added}"
puts "oimlcs stamped on #{oimlcs_files} records"
puts "files touched: #{changed.size}"
