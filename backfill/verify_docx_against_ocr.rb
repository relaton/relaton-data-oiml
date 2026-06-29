# frozen_string_literal: true

# One-off: verify my regex-based docx parser (docx_articles.yaml) against
# GLM OCR's independent read of the same contents.docx (rendered to PDF).
# NOT maintained.
#
# Both should produce the same (year, bulletin_no, entry-count) structure.
# Discrepancies flag parser bugs in either direction.
#
# Run:
#   bundle exec ruby backfill/verify_docx_against_ocr.rb

require "yaml"

module BulletinBackfill
  class VerifyDocxAgainstOcr
    attr_reader :discrepancies, :stats

    def initialize(docx_yaml:, ocr_md:)
      @docx_yaml = docx_yaml
      @ocr_md = ocr_md
      @discrepancies = []
      @stats = { docx_issues: 0, ocr_issues: 0, matched: 0 }
    end

    def verify
      docx_counts = count_docx_per_issue
      ocr_counts = parse_ocr_counts

      all_keys = (docx_counts.keys + ocr_counts.keys).uniq.sort
      all_keys.each do |key|
        d = docx_counts[key] || 0
        o = ocr_counts[key] || 0
        if d.zero? && o.zero?
          nil
        elsif d == o
          @stats[:matched] += 1
        else
          @discrepancies << { issue: key, docx: d, ocr: o, diff: d - o }
        end
      end
      @stats[:docx_issues] = docx_counts.size
      @stats[:ocr_issues] = ocr_counts.size
      self
    end

    private

    def count_docx_per_issue
      YAML.load_file(@docx_yaml).each_with_object(Hash.new(0)) do |e, h|
        next unless e["year"] && e["bulletin_no"]

        h[[e["year"], e["bulletin_no"]]] += 1
      end
    end

    # The OCR'd contents.docx renders as markdown with structure:
    #   ## YEAR
    #   ## N.            <- bulletin_no (cumulative or quarterly)
    #   - article 1
    #   - article 2
    #   ## N+1.
    #   - ...
    # Count bullets under each (year, bulletin_no).
    def parse_ocr_counts
      counts = Hash.new(0)
      current_year = nil
      current_no = nil

      @ocr_md.lines.each do |line|
        line = line.strip
        if line =~ /\A##\s+(\d{4})\s*\z/
          current_year = Regexp.last_match(1).to_i
          current_no = nil
        elsif line =~ /\A##\s+(\d+)[\.\s]/
          # New bulletin_no header. Skip false positives like "## 1." in body.
          if current_year
            current_no = Regexp.last_match(1).to_i
          end
        elsif line.start_with?("- ") && current_year && current_no
          counts[[current_year, current_no]] += 1
        end
      end
      counts
    end
  end
end

if $PROGRAM_NAME == __FILE__
  docx_yaml = "backfill/cache/docx_articles.yaml"
  ocr_md_path = "backfill/cache/contents_docx_ocr.md"
  abort "missing #{docx_yaml}" unless File.exist?(docx_yaml)
  abort "missing #{ocr_md_path} (run glm_ocr.rb on the contents PDF first)" unless File.exist?(ocr_md_path)

  v = BulletinBackfill::VerifyDocxAgainstOcr.new(
    docx_yaml: docx_yaml, ocr_md: File.read(ocr_md_path),
  ).verify

  puts "=== docx parser vs GLM-OCR cross-check ==="
  puts "docx-issues: #{v.stats[:docx_issues]}, ocr-issues: #{v.stats[:ocr_issues]}, matched: #{v.stats[:matched]}"
  puts "discrepancies: #{v.discrepancies.size}"
  if v.discrepancies.any?
    puts "\nyear | no | docx | ocr | diff"
    v.discrepancies.first(40).each do |d|
      puts "#{d[:issue][0]} | #{d[:issue][1]} | #{d[:docx]} | #{d[:ocr]} | #{d[:diff]}"
    end
    puts "..." if v.discrepancies.size > 40
  end

  total_docx = v.discrepancies.sum { |d| d[:docx] }
  total_ocr = v.discrepancies.sum { |d| d[:ocr] }
  puts "\nAcross all discrepant issues: docx has #{total_docx} entries, OCR sees #{total_ocr}."
end
