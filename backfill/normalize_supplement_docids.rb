#!/usr/bin/env ruby
# One-off: normalize OIML amendment/errata docids to canonical forms.
#
# Amendments → joined form: BASE:YEAR+Amendment:AMD_YEAR
# Errata    → trailing form: BASE:YEAR Errata
#
# Also deletes duplicate amendment records (consolidated-text dups and
# legacy "-Amend:" duplicates of the PartsBuilder-emitted "-YEARamendment" files).

require "fileutils"

# Mapping: (old_stem_prefix, new_docid_base, amd_year) → list of language suffixes to migrate
AMENDMENTS = {
  # old_prefix                         base (with year)             amd_year
  "b10-1-amend_2006"  => ["OIML B 10-1:2004+Amendment:2006", 2006],
  "b10-amend_2012"    => ["OIML B 10:2011+Amendment:2012",   2012],
  "b3-amend_2006"     => ["OIML B 3:2003+Amendment:2006",    2006],
  "d2-amend_2004"     => ["OIML D 2:1999+Amendment:2004",    2004],
  "r138-2009amendment" => ["OIML R 138:2007+Amendment:2009", 2009],
  "r137-1-2-2014amendment" => ["OIML R 137-1-2:2012+Amendment:2014", 2014],
  "r35-1-2014amendment" => ["OIML R 35-1:2007+Amendment:2014", 2014],
  "r60-2019amendment" => ["OIML R 60:2017+Amendment:2019",   2019],
}

# Old docid string that the file currently has (for in-place replacement)
OLD_DOCID = {
  "b10-1-amend_2006"  => "OIML B 10-1-Amend:2006",
  "b10-amend_2012"    => "OIML B 10-Amend:2012",
  "b3-amend_2006"     => "OIML B 3-Amend:2006",
  "d2-amend_2004"     => "OIML D 2-Amend:2004",
  "r138-2009amendment" => "OIML R 138:2009 Amendment",
  "r137-1-2-2014amendment" => "OIML R 137-1-2:2014 Amendment",
  "r35-1-2014amendment" => "OIML R 35-1:2014 Amendment",
  "r60-2019amendment" => "OIML R 60:2019 Amendment",
}

LANG_SUFFIXES = ["", "_eng", "_fra", "_deu", "_fas", "_spa", "_ara", "_zho"]

def docid_with_lang(docid_base, lang_suffix)
  return docid_base if lang_suffix.empty?

  lang_map = {"_eng"=>"E", "_fra"=>"F", "_deu"=>"D", "_fas"=>"PE", "_spa"=>"S",
              "_ara"=>"A", "_zho"=>"C"}
  code = lang_map[lang_suffix] or return docid_base
  "#{docid_base} (#{code})"
end

def new_filename_base(docid_base)
  # OIML B 10-1:2004+Amendment:2006 → b10-1-2004amendment_2006
  m = docid_base.match(/^OIML ([A-Z])\s+(\d+(?:-\d+)*)/)
  prefix = m[1].downcase
  number = m[2]
  base_year = docid_base[/:(\d{4})\+/, 1]
  amd_year = docid_base[/Amendment:(\d{4})/, 1]
  "#{prefix}#{number}-#{base_year}amendment_#{amd_year}"
end

def update_file(path, old_docid_variants, new_docid)
  return unless File.exist?(path)
  content = File.read(path, encoding: "UTF-8")
  original = content
  old_docid_variants.each do |old|
    content.gsub!(old, new_docid)
  end
  File.write(path, content, encoding: "UTF-8") if content != original
end

# 1. Delete duplicates
DUPLICATES = [
  "data/b10-amended_2012_2011.yaml",
  "data/b10-amended_2012_2011_eng.yaml",
  "data/b10-amended_2012_2011_fra.yaml",
  "data/r138-amend_2009.yaml",
  "data/r138-amend_2009_eng.yaml",
  "data/r138-amend_2009_fra.yaml",
]
DUPLICATES.each do |f|
  if File.exist?(f)
    File.delete(f)
    puts "deleted: #{f}"
  end
end

# 2. Rename + update amendments
AMENDMENTS.each do |old_prefix, (new_docid_base, _amd_year)|
  new_prefix = new_filename_base(new_docid_base)
  old_docid = OLD_DOCID[old_prefix]

  LANG_SUFFIXES.each do |lang|
    old_file = "data/#{old_prefix}#{lang}.yaml"
    next unless File.exist?(old_file)

    new_file = "data/#{new_prefix}#{lang}.yaml"
    new_docid = docid_with_lang(new_docid_base, lang)

    # In-place update docid content
    old_docid_variants = if lang.empty?
                           [old_docid]
                         else
                           lang_code = {"_eng"=>"(E)", "_fra"=>"(F)", "_deu"=>"(D)",
                                        "_fas"=>"(PE)", "_spa"=>"(S)", "_ara"=>"(A)",
                                        "_zho"=>"(C)"}[lang]
                           [old_docid + " " + lang_code]
                         end

    # also fix the `id:` field
    content = File.read(old_file, encoding: "UTF-8")
    content.gsub!(/^id: .+$/, "id: #{new_prefix.sub('amendment', 'Amendment')}#{lang.tr('_', '-')}")
    # actually compute id properly
    new_id = new_prefix.dup
    new_id << lang.tr('_', '-') unless lang.empty?
    content = File.read(old_file, encoding: "UTF-8")
    content.gsub!(/^id: .+$/, "id: #{new_id}")
    old_docid_variants.each { |old| content.gsub!(old, new_docid) }
    # Also fix the bare form (without lang)
    content.gsub!(old_docid, new_docid_base)
    File.write(old_file, content, encoding: "UTF-8")

    # Rename file
    if old_file != new_file
      File.rename(old_file, new_file)
      puts "renamed: #{old_file} → #{new_file}"
    end
  end
end

# 3. Fix V 2-200 erratum → Errata
V_OLD_PREFIX = "v2-200-erratum_2010"
V_NEW_PREFIX = "v2-200-2007errata_2010"
V_OLD_DOCID = "OIML V 2-200-erratum:2010"
V_NEW_DOCID = "OIML V 2-200:2007 Errata"

LANG_SUFFIXES.each do |lang|
  old_file = "data/#{V_OLD_PREFIX}#{lang}.yaml"
  next unless File.exist?(old_file)

  new_file = "data/#{V_NEW_PREFIX}#{lang}.yaml"
  lang_code = {"_eng"=>" (E)", "_fra"=>" (F)"}[lang]
  new_docid = V_NEW_DOCID + (lang_code || "")
  old_docid_with_lang = V_OLD_DOCID + (lang_code || "")

  content = File.read(old_file, encoding: "UTF-8")
  new_id = V_NEW_PREFIX + (lang.empty? ? "" : lang.tr('_', '-'))
  content.sub!(/^id: .+$/, "id: #{new_id}")
  content.gsub!(old_docid_with_lang, new_docid)
  content.gsub!(V_OLD_DOCID, V_NEW_DOCID)
  File.write(old_file, content, encoding: "UTF-8")
  File.rename(old_file, new_file) if old_file != new_file
  puts "fixed: #{old_file} → #{new_file}"
end

# 4. Rename r126-erratum-2012_spa.yaml → r126-2012errata_spa.yaml
R126_OLD = "data/r126-erratum-2012_spa.yaml"
R126_NEW = "data/r126-2012errata_spa.yaml"
if File.exist?(R126_OLD)
  content = File.read(R126_OLD, encoding: "UTF-8")
  content.sub!(/^id: .+$/, "id: r126-2012errata-spa")
  File.write(R126_OLD, content, encoding: "UTF-8")
  File.rename(R126_OLD, R126_NEW)
  puts "renamed: #{R126_OLD} → #{R126_NEW}"
end

puts "\nDone."
