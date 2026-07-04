#!/usr/bin/env ruby
# One-off: fix `id:` field in normalized amendment/errata YAMLs to canonical
# CamelCase form (e.g. R137-1-2-2012Amendment-2014).

FILES = Dir["data/*amendment_*.yaml", "data/*errata_*.yaml", "data/*errata-*.yaml"]

FILES.each do |f|
  basename = File.basename(f, ".yaml")
  # r137-1-2-2012amendment_2014 → R137-1-2-2012Amendment-2014
  normalized = basename.sub(/\A([a-z])/, '\1').capitalize
  # capitalize first letter only — capitalize lowercases the rest
  normalized = basename.gsub(/^([a-z])/) { $1.upcase }
                       .gsub(/amendment/, "Amendment")
                       .gsub(/errata/, "Errata")
                       .gsub("_", "-")
  content = File.read(f, encoding: "UTF-8")
  new_content = content.sub(/^id: .+$/, "id: #{normalized}")
  if new_content != content
    File.write(f, new_content, encoding: "UTF-8")
    puts "fixed id: #{f} → #{normalized}"
  end
end
