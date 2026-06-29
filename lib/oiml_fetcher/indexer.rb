# frozen_string_literal: true

require "relaton/index"
require "relaton/bib"

module OimlFetcher
  # Builds the docid → file-path index over data/*.yaml using relaton-index.
  #
  # No type-specific logic — works uniformly for works, instances, and
  # translations. The index mirrors the data/ directory exactly on every run.
  module Indexer
    module_function

    # @param data_dir [String] directory of data/*.yaml files to index
    # @param index_file [String] path to the index YAML to (re)write
    # @return [Relaton::Index::Type] the built index
    def build(data_dir:, index_file:)
      idx = Relaton::Index.find_or_create :OIML, file: index_file
      # find_or_create loads the existing index and add_or_update never prunes;
      # clearing first means deleted/renamed data files drop out instead of
      # lingering as orphan entries.
      idx.remove_all
      base = File.dirname(File.expand_path(index_file))

      Dir[File.join(data_dir, "*.yaml")].sort.each do |f|
        item = Relaton::Bib::Item.from_yaml(File.read(f, encoding: "UTF-8"))
        docid = item.docidentifier.find(&:primary) || item.docidentifier.first
        unless docid
          warn "Error processing #{f}: no docidentifier"
          next
        end
        idx.add_or_update docid.content, File.expand_path(f).delete_prefix("#{base}/")
      rescue StandardError => e
        warn "Error processing #{f}: #{e.message}"
      end

      idx.save
      idx
    end
  end
end
