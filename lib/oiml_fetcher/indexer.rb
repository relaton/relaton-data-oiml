# frozen_string_literal: true

require "relaton/index"
require "relaton/bib"

module OimlFetcher
  # Builds the docid → file-path index over data/*.yaml using relaton-index.
  #
  # No type-specific logic — works uniformly for works, instances, and
  # translations. The index mirrors the data/ directory exactly on every run.
  #
  # Two index flavours, built in a single pass:
  #   * index-v1.yaml  — flat string docid → file
  #   * index-v2.yaml  — structured pubid identifier → file (when index_v2_file
  #     is given), parsed via pubid v2's OIML support
  module Indexer
    module_function

    # @param data_dir [String] directory of data/*.yaml files to index
    # @param index_file [String] path to the v1 (string) index YAML to (re)write
    # @param index_v2_file [String, nil] path to the v2 (structured pubid) index;
    #   skipped when nil
    # @return [Array(Relaton::Index::Type, Relaton::Index::Type)] the v1 index
    #   and the v2 index; the second element is nil when index_v2_file is nil
    def build(data_dir:, index_file:, index_v2_file: nil)
      idx = clean_index(file: index_file)
      idx2 = structured_index(index_v2_file)
      base = File.dirname(File.expand_path(index_file))

      Dir[File.join(data_dir, "*.yaml")].sort.each do |f|
        item = Relaton::Bib::Item.from_yaml(File.read(f, encoding: "UTF-8"))
        docid = item.docidentifier.find(&:primary) || item.docidentifier.first
        unless docid
          warn "Error processing #{f}: no docidentifier"
          next
        end
        rel = File.expand_path(f).delete_prefix("#{base}/")
        idx.add_or_update docid.content, rel
        add_pubid(idx2, docid.content, rel) if idx2
      rescue StandardError => e
        warn "Error processing #{f}: #{e.message}"
      end

      idx.save
      idx2&.save
      [idx, idx2]
    end

    # find_or_create loads the existing index and add_or_update never prunes;
    # clearing first means deleted/renamed data files drop out instead of
    # lingering as orphan entries.
    def clean_index(file:, pubid_class: nil)
      idx = Relaton::Index.find_or_create :OIML, file: file, pubid_class: pubid_class
      idx.remove_all
      idx
    end

    def structured_index(file)
      return nil unless file

      require "pubid"
      clean_index(file: file, pubid_class: Pubid::Oiml::Identifier)
    end

    # A docid that pubid cannot parse must not drop the file from the v2 index
    # silently breaking the v1/v2 pairing — warn and skip just the v2 entry.
    def add_pubid(idx2, content, rel)
      idx2.add_or_update Pubid::Oiml.parse(content), rel
    rescue StandardError => e
      warn "Skipping #{content} in index-v2: #{e.message}"
    end
  end
end
