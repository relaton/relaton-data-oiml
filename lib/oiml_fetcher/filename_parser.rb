# frozen_string_literal: true

module OimlFetcher
  # Top-level wrapper around +OimlFetcher::Docid.from_pdf_filename+.
  # Kept as its own module so tests and callers can target the filename
  # grammar directly without dragging in PartsBuilder.
  #
  # Returns an +OimlFetcher::Docid+ (or +nil+ on parse failure).
  class FilenameParser
    def self.parse(filename)
      OimlFetcher::Docid.from_pdf_filename(filename)
    end
  end
end
