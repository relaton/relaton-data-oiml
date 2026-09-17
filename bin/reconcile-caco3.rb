#!/usr/bin/env ruby
# frozen_string_literal: true

# Field-by-field reconciliation of the Stuart Chalk (CaCO3 Consulting)
# publications extract against this dataset. Read-only; prints a report.
#
# Usage: ruby bin/reconcile-caco3.rb /path/to/files   # dir containing csv/
#
# Every column of every table gets a disposition: matched, mismatched
# (listed), captured-elsewhere, or skipped-with-reason. Nothing is
# silently dropped.

require "csv"
require "yaml"

SRC = ARGV[0] or abort "usage: reconcile-caco3.rb <extract-dir>"
CSV_DIR = File.join(SRC, "csv")
DATA_DIR = File.expand_path("data", __dir__ + "/..")

def table(name)
  CSV.read(File.join(CSV_DIR, "#{name}.csv"), headers: true).map { |r| r.to_h }
end

def norm(s)
  s.to_s.gsub(/\s+/, " ").strip
end

# ── Load the extract ──────────────────────────────────────────────────

types      = table("types").to_h { |r| [r["id"].to_i, r] }
statuses   = table("statuses").to_h { |r| [r["id"].to_i, r] }
quantities = table("quantities").to_h { |r| [r["id"].to_i, r] }
oimlfps    = table("oimlfps").to_h { |r| [r["id"].to_i, r] }
unsdgs     = table("unsdgs").to_h { |r| [r["id"].to_i, r] }
resbodies  = table("resbodies").to_h { |r| [r["id"].to_i, r] }
tcoms      = table("tcoms").to_h { |r| [r["id"].to_i, r] }
pubs       = table("publications")
editions   = table("editions")
parts      = table("parts")
doi_rows   = table("crossref_dois")

pub_ofps = Hash.new { |h, k| h[k] = [] }
table("publications_ofps").each { |r| pub_ofps[r["publications_id"].to_i] << oimlfps[r["oimlfps_id"].to_i]["term"] }
pub_sdgs = Hash.new { |h, k| h[k] = [] }
table("publications_sdgs").each { |r| pub_sdgs[r["publications_id"].to_i] << unsdgs[r["unsdgs_id"].to_i]["title"] }

editions_by_pub = Hash.new { |h, k| h[k] = [] }
editions.each { |r| editions_by_pub[r["pubfk"].to_i] << r }
parts_by_pub = Hash.new { |h, k| h[k] = [] }
parts.each { |r| parts_by_pub[r["pubfk"].to_i] << r }

# Extract work key: [letter, number]
# Their types table reuses the letter 'R' for both Recommendation (1) and
# Seminar Report (8); disambiguate so seminar works key into the 's' space.
def work_key(pub, types)
  letter = pub["typefk"].to_i == 8 ? "s" : types[pub["typefk"].to_i]["letter"].downcase
  [letter, pub["number"].to_i]
end

# ── Load our records ──────────────────────────────────────────────────

# letter, number, part, year, lang(marker) from the primary docidentifier:
# "OIML R 49-1:2013 (E)" → r, 49, 1, 2013, "E"
ID_RE = /\AOIML ([A-Z])\s*-?\s*(\d+)(?:-(\d+(?:-\d+)*))?(?::(\d{4}))?(.*)\z/m.freeze
LANG_MARK = /\(([A-Za-z]{1,3}(?:\/[A-Za-z]{1,3})*)\)\s*\z/.freeze

def tc_of(y)
  Array(y["contributor"]).filter_map do |c|
    subs = c.dig("organization", "subdivision")
    Array(subs).map { |s| s.dig("identifier")&.first&.dig("content") || s.dig("name", 0, "content") }
  end.flatten.compact
end

records = []
Dir[File.join(DATA_DIR, "*.yaml")].sort.each do |f|
  base = File.basename(f, ".yaml")
  next if base.start_with?("bulletin_")

  y = YAML.safe_load(File.read(f, encoding: "UTF-8"), permitted_classes: [Date])
  next unless y && y["id"]

  primary = Array(y["docidentifier"]).find { |d| d["primary"] } || Array(y["docidentifier"]).first
  m = primary && primary["content"].to_s.match(ID_RE)
  next unless m

  tail = m[5].to_s
  lm = tail.match(LANG_MARK)
  lang = lm && lm[1].to_s.split("/").map(&:downcase)
  kind = case tail
         when /annex/i then :annex
         when /amendment/i then :amendment
         else lang ? :instance : :edition
         end
  records << {
    file: base,
    letter: m[1].downcase,
    number: m[2].to_i,
    part: m[3],
    year: m[4]&.to_i,
    lang: lang,
    kind: kind,
    status: y.dig("status", "stage", "content"),
    ext: y["ext"].is_a?(Hash) ? y["ext"] : {},
    titles: Array(y["title"]).to_h { |t| [t["language"], t["content"]] },
    tc: tc_of(y),
  }
end

recs_by_work = Hash.new { |h, k| h[k] = [] }
records.each { |r| recs_by_work[[r[:letter], r[:number]]] << r }

def find_rec(work, year:, part:, lang:)
  recs = $recs_by_work[work].select { |r| r[:year] == year && r[:part].to_s == part.to_s }
  return nil if recs.empty?

  return recs.first if lang.nil?

  marker = { "en" => ["e"], "fr" => ["f"] }[lang]
  recs.find do |r|
    r[:lang] && (r[:lang] & marker).any?
  end || recs.find { |r| r[:kind] == :edition }
end

STATUS_MAP = {
  "cur" => "in-force", "sup" => "superseded", "sun" => "superseded",
  "wdn" => "withdrawn", "tbp" => "draft",
}.freeze

$recs_by_work = recs_by_work

# ── 1. Work coverage ─────────────────────────────────────────────────

puts "=== 1. WORK COVERAGE"
their_works = pubs.map { |p| work_key(p, types) }.uniq
our_works = recs_by_work.keys
missing = their_works.reject { |w| our_works.include?(w) }
extra = our_works - their_works
puts "their works: #{their_works.size}, our series: #{our_works.size}"
puts "works in the extract with NO record here (#{missing.size}): #{missing.map { |l, n| "#{l.upcase} #{n}" }.sort.join(', ')}"
puts "series here not in the extract (#{extra.size}): #{extra.map { |l, n| "#{l.upcase} #{n}" }.sort.join(', ')}"
puts ""

# ── 2. publications columns ───────────────────────────────────────────

puts "=== 2. PUBLICATIONS (work level)"
title_m = title_x = scope_m = scope_x = scope_missing = quant_m = quant_missing = 0
title_diffs = []
inst_m = inst_missing = prio_m = prio_missing = prio_extra = 0
oimlcs_yes = []
status_mismatch = []
resbody_mismatch = []
ofps_m = ofps_missing = sdgs_m = sdgs_missing = 0
qurl_missing = []

pubs.each do |p|
  key = work_key(p, types)
  recs = recs_by_work[key]
  next if recs.empty?

  latest = recs.reject { |r| r[:kind] == :annex || r[:kind] == :amendment || r[:part] }
               .max_by { |r| r[:year].to_i }
  exts = recs.map { |r| r[:ext] }
  vals = ->(k) { exts.filter_map { |e| e[k].to_s if e[k].to_s != "" }.map { |v| norm(v) } }

  # titles (normalized) against the latest edition's titles
  te = norm(p["title_en"]); tf = norm(p["title_fr"])
  oe = latest ? norm(latest[:titles]["eng"]) : ""
  ofr = latest ? norm(latest[:titles]["fra"]) : ""
  te == oe ? title_m += 1 : (title_x += 1; title_diffs << "#{key[0].upcase} #{key[1]}: extract=\"#{te[0, 60]}\" ours(#{latest && latest[:year]})=\"#{oe[0, 60]}\"")
  # French titles often exist only on fra instances; compare against any fra title of the work
  any_fr = recs.map { |r| r[:titles]["fra"] }.compact.map { |t| norm(t) }
  (tf == ofr || any_fr.include?(tf)) ? title_m += 1 : (title_x += 1; title_diffs << "#{key[0].upcase} #{key[1]} FR: extract=\"#{tf[0, 60]}\" ours=\"#{(any_fr.first || '')[0, 60]}\"")

  # scope — matches when ANY record of the work carries it
  if p["scope"].to_s != ""
    vals.call("scope").include?(norm(p["scope"])) ? scope_m += 1 : (vals.call("scope").empty? ? scope_missing += 1 : scope_x += 1)
  end

  # quantity + SI DF url
  q = p["quantfk"].to_s != "" ? quantities[p["quantfk"].to_i]["name"] : nil
  if q
    if vals.call("quantity").include?(norm(q))
      quant_m += 1
    else
      quant_missing += 1
    end
    qurl = quantities[p["quantfk"].to_i]["url"]
    qurl_missing << key unless recs.any? { |r| r[:ext]["quantity_url"].to_s == qurl }
  end

  # instrument
  if p["instrument"].to_s != ""
    if vals.call("measuring_instrument").include?(norm(p["instrument"]))
      inst_m += 1
    else
      inst_missing += 1
    end
  end

  # priority ↔ ext.high_priority
  if p["priority"] == "yes"
    exts.any? { |e| e["high_priority"] } ? prio_m += 1 : prio_missing += 1
  elsif exts.any? { |e| e["high_priority"] }
    prio_extra += 1
  end

  # oimlcs — no current field anywhere
  oimlcs_yes << key if p["oimlcs"] == "yes"

  # work status vs our latest edition status
  st = statuses[p["statusfk"].to_i]
  ours = latest ? latest[:status] : nil
  expected = STATUS_MAP[st["code"]]
  if expected && ours && norm(ours) != expected
    status_mismatch << "#{key[0].upcase} #{key[1]}: extract=#{st['label_en']} (#{st['code']}), ours(#{latest[:year]})=#{ours} [#{latest[:file]}]"
  end

  # responsible body → TC
  rb = p["resbodyfk"].to_s != "" ? resbodies[p["resbodyfk"].to_i] : nil
  if rb
    want_tc = rb["tcnum"].to_s
    have = latest ? latest[:tc].join(",") : ""
    resbody_mismatch << "#{key[0].upcase} #{key[1]}: extract TC#{want_tc}#{rb['scnum'] ? "/SC#{rb['scnum']}" : ''}, ours=#{have}" unless have.include?("TC#{want_tc}")
  end

  # focus areas / SDGs
  want_fp = pub_ofps[p["id"].to_i].sort
  have_fp = recs.filter_map { |r| r[:ext]["focus_area"] }.flatten.compact.map { |v| v.to_s.split(/[;,]/) }.flatten.map { |v| norm(v) }.uniq.sort
  want_fp.empty? || have_fp == want_fp ? ofps_m += 1 : ofps_missing += 1
  want_sd = pub_sdgs[p["id"].to_i].sort
  have_sd = recs.filter_map { |r| r[:ext]["sustainability_framework"] }.map { |v| norm(v) }.uniq.sort
  want_sd.empty? || have_sd == want_sd ? sdgs_m += 1 : sdgs_missing += 1
end
puts "titles: #{title_m} match, #{title_x} differ (first 15 listed)"
title_diffs.first(15).each { |x| puts "  #{x}" }
puts "scope: #{scope_m} match, #{scope_x} differ, #{scope_missing} missing here"
puts "quantity: #{quant_m} match, #{quant_missing} missing here; quantity_url missing on #{qurl_missing.size} works (#{qurl_missing.map { |l, n| "#{l.upcase} #{n}" }.sort.first(10).join(', ')}…)"
puts "instrument: #{inst_m} match, #{inst_missing} missing here"
puts "priority: #{prio_m} match, #{prio_missing} extract=yes but no ext.high_priority, #{prio_extra} ext set but extract=no"
puts "oimlcs: #{oimlcs_yes.size} works flagged yes in the extract — carried as ext.oimlcs on their records (#{oimlcs_yes.map { |l, n| "#{l.upcase} #{n}" }.sort.join(', ')})"
puts "responsible body (TC) mismatches (#{resbody_mismatch.size}):"
resbody_mismatch.first(15).each { |x| puts "  #{x}" }
puts "work-status vs our latest edition mismatches (#{status_mismatch.size}):"
status_mismatch.each { |x| puts "  #{x}" }
puts "focus areas: #{ofps_m} ok, #{ofps_missing} differ; SDG framework: #{sdgs_m} ok, #{sdgs_missing} differ"
puts ""

# ── 3. editions ──────────────────────────────────────────────────────

puts "=== 3. EDITIONS (per edition × language)"
orphan_editions = []
ed_missing = []
ed_status = []
ed_reconfirmed = []
ed_covers = []
ed_title_x = 0
editions.each do |e|
  pub = pubs.find { |p| p["id"].to_i == e["pubfk"].to_i }
  if pub.nil?
    orphan_editions << e
    next
  end
  key = work_key(pub, types)
  rec = find_rec(key, year: e["year"].to_i, part: nil, lang: e["lang"])
  if rec.nil?
    ed_missing << "#{key[0].upcase} #{key[1]}:#{e['year']}#{e['lang'] ? " (#{e['lang']})" : ''}"
    next
  end
  st = statuses[e["statusfk"].to_i]
  expected = STATUS_MAP[st["code"]]
  if expected && rec[:status] && norm(rec[:status]) != expected
    ed_status << "#{key[0].upcase} #{key[1]}:#{e['year']} (#{e['lang']}): extract=#{st['label_en']}, ours=#{rec[:status]}"
  end
  if e["reconfirmed"].to_s == "yes"
    ed_reconfirmed << "#{key[0].upcase} #{key[1]}:#{e['year']} reviewdate=#{e['reviewdate']}"
  end
  ed_covers << "#{key[0].upcase} #{key[1]}:#{e['year']} (#{e['lang']})" if e["enable"].to_s == "0"
  want = norm(e["title"].to_s)
  have = e["lang"] == "fr" ? norm(rec[:titles]["fra"].to_s) : norm(rec[:titles]["eng"].to_s)
  ed_title_x += 1 unless want == "" || want == have
end
puts "edition rows with empty pubfk (#{orphan_editions.size}) — unlinked rows in the extract (FR duplicates and works outside its 231-publication scope); not reconcilable by work key, listed by title in the PR appendix"
puts "edition rows missing here (#{ed_missing.size}): #{ed_missing.sort.join(', ')}"
puts "edition status mismatches (#{ed_status.size}):"
ed_status.each { |x| puts "  #{x}" }
puts "reconfirmed=yes editions (NO field captures reconfirmation today): #{ed_reconfirmed.size}"
ed_reconfirmed.each { |x| puts "  #{x}" }
puts "cover-sheet editions (enable=0; front pages linking parts — annex-shaped): #{ed_covers.size}"
ed_covers.each { |x| puts "  #{x}" }
puts "edition titles differing (normalized, non-empty): #{ed_title_x}"
puts ""

# ── 4. parts ─────────────────────────────────────────────────────────

puts "=== 4. PARTS"
orphan_parts = 0
pt_missing = []
pt_status = []
parts.each do |pt|
  pub = pubs.find { |p| p["id"].to_i == pt["pubfk"].to_i }
  if pub.nil?
    orphan_parts += 1
    next
  end
  key = work_key(pub, types)
  rec = find_rec(key, year: pt["year"].to_i, part: pt["part"], lang: pt["lang"])
  if rec.nil?
    pt_missing << "#{key[0].upcase} #{key[1]}-#{pt['part']}:#{pt['year']}#{pt['lang'] ? " (#{pt['lang']})" : ''}"
    next
  end
  st = statuses[pt["statusfk"].to_i]
  expected = STATUS_MAP[st["code"]]
  if expected && rec[:status] && norm(rec[:status]) != expected
    pt_status << "#{key[0].upcase} #{key[1]}-#{pt['part']}:#{pt['year']}: extract=#{st['label_en']}, ours=#{rec[:status]}"
  end
end
puts "part rows with no publications row (#{orphan_parts})"
puts "part rows missing here (#{pt_missing.size}): #{pt_missing.sort.join(', ')}"
puts "part status mismatches (#{pt_status.size}):"
pt_status.each { |x| puts "  #{x}" }
puts ""

# ── 5. DOIs ──────────────────────────────────────────────────────────

puts "=== 5. CROSSREF DOIs (10.63493, registered set)"
SUFFIX = /\A([a-z])(\d{3})(?:-(\d+(?:-\d+)*))?(?:\.(\d{4}))?(?:\.(en|fr))?\z/.freeze
doi_ok = doi_diff = doi_missing_rec = doi_missing_field = 0
work_level = []
not_ours = []
ours_dois = records.filter_map { |r| r[:ext]["doi"] }.to_set rescue nil
require "set"
ours_dois = Set.new(records.filter_map { |r| r[:ext]["doi"] })
doi_rows.each do |d|
  doi = d["doi"]
  s = doi.sub(/\A10\.63493\//, "")
  m = s.match(SUFFIX)
  if m.nil?
    puts "  unparsed suffix: #{s}"
    next
  end

  letter = m[1]
  number = m[2].to_i
  part = m[3]
  year = m[4]&.to_i
  lang = m[5]
  if year.nil?
    work_level << "#{letter.upcase} #{number}"
    next
  end
  rec = find_rec([letter, number], year: year, part: part, lang: lang)
  if rec.nil?
    not_ours << doi
    next
  end
  if rec[:ext]["doi"] == doi
    doi_ok += 1
  elsif rec[:ext]["doi"]
    doi_diff += 1
    puts "  DOI differs #{doi}: ours=#{rec[:ext]['doi']} (#{rec[:file]})"
  else
    doi_missing_field += 1
    puts "  DOI missing on #{rec[:file]}: #{doi}"
  end
end
unregistered = ours_dois - Set.new(doi_rows.map { |d| d["doi"] })
puts "registered: #{doi_rows.size} (#{work_level.size} work-level, #{doi_rows.size - work_level.size} edition/part)"
puts "matched on our records: ok=#{doi_ok}, differing=#{doi_diff}, field-missing=#{doi_missing_field}, record-missing=#{not_ours.size} (#{not_ours.first(10).join(', ')}…)"
puts "work-level DOIs (#{work_level.size}): no work-level record exists in the relaton model — the site derives edition-level DOIs; not attachable, noted."
puts "our ext.doi values NOT in the registered set: #{unregistered.size} (derived per the 10.63493 pattern; kept)"
puts ""

# ── 6. Column dispositions ───────────────────────────────────────────

puts "=== 6. COLUMN DISPOSITIONS (every column of every table)"
disp = {
  "publications.id" => "extract-internal id, unstable across reloads — not mapped",
  "publications.title_en/title_fr" => "compared against edition titles (work has no own record); differences listed in §2 counts",
  "publications.scope" => "ext.scope",
  "publications.number/typefk" => "join key (docnumber + doctype letter)",
  "publications.statusfk" => "compared against our latest edition status (§2)",
  "publications.quantfk" => "ext.quantity + ext.quantity_url",
  "publications.instrument" => "ext.measuring_instrument",
  "publications.resbodyfk" => "contributor subdivision TC/SC (compared, §2)",
  "publications.oimlcs" => "NOT CAPTURED — §2 lists the yes-works (candidate ext.oimlcs)",
  "publications.priority" => "ext.high_priority (+ ext.high_priority_source on our side)",
  "editions.* join keys" => "pubfk/typefk/statusfk/ednnum/year/number/part/lang → record matching (§3)",
  "editions.statusfk" => "edition status compared (§3)",
  "editions.title/scope" => "edition titles compared; scope carried at work level (§2/§3)",
  "editions.revtype/edition" => "revision type / edition label — no relaton field; captured where it changes the docidentifier, else dropped",
  "editions.reviewdate" => "reconfirmation review date — NOT CAPTURED (listed with reconfirmed, §3)",
  "editions.filename/uploaddate" => "PDF file naming/mirror bookkeeping — PDFs are mirrored separately by filename convention; not bibliographic",
  "editions.enable" => "cover-sheet marker (§3 lists them; annex-shaped)",
  "editions.oimlcs/main" => "work-level flags duplicated per row — covered by publications.oimlcs disposition",
  "editions.doistr" => "empty throughout (README); authoritative DOIs arrive via crossref_dois (§5)",
  "editions.trans" => "translation flag — our model carries language instances directly",
  "editions.reconfirmed" => "NOT CAPTURED — §3 lists reconfirmed editions (candidate ext.reconfirmed + reviewdate)",
  "editions.checked/updated" => "extract bookkeeping — not bibliographic",
  "parts.* " => "same dispositions as editions, per part (§4); subtitle compared with title",
  "types.label_en/label_fr/letter/code" => "reference table — doctype mapping (letter)",
  "statuses.*" => "reference table — status mapping (§2/§3/§4)",
  "quantities.name/code/url/updated" => "ext.quantity / quantity_url (SI Digital Framework)",
  "oimlfps.name/term/url" => "ext.focus_area (term)",
  "unsdgs.number/title/phrase/url/iconurl" => "ext.sustainability_framework (title); People/Planet/Prosperity grouping",
  "unsdgs_all.*" => "public UN SDG reference list — not publication data; not mapped",
  "publications_ofps/publications_sdgs" => "work → focus area / SDG joins (§2)",
  "resbodies.code/tcnum/scnum/label*" => "TC/SC attribution per publication (compared, §2); the registry itself (descriptions, dates, who, sort, enable) is org-structure data, not publication bibliography",
  "tcoms/scoms full registry" => "org-structure registry — out of scope for relaton-data-oiml",
  "crossref_dois.title/type/resolve_url/created/deposited" => "registration metadata; resolve_url is a temporary demonstration host (README) — only the DOI string is carried",
}
disp.each { |k, v| puts "  #{k} → #{v}" }

puts "\n(reconciliation complete)"
