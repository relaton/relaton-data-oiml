# frozen_string_literal: true

source "https://rubygems.org"

# Pin psych: 5.3.0 silently breaks the YAML round-trip that check_data.rb
# depends on (key ordering / quoting differences). Documented in
# relaton-data-iho Gemfile.
gem "psych", "~> 5.2.6"

# relaton-bib + transitive deps live in the relaton/relaton monorepo. Pull
# them from main via HTTPS so the GH Action can clone anonymously (no SSH
# key). Glob matches relaton-data-iho/Gemfile exactly.
git "https://github.com/relaton/relaton.git",
    branch: "main", glob: "gems/*/*.gemspec" do
  gem "relaton-bib"
  gem "relaton-core"
  gem "relaton-index"
  gem "relaton-logger"
end

# When relaton-oiml is published, swap the above block for:
#   gem "relaton-oiml", git: "https://github.com/relaton/relaton.git",
#                       branch: "main", glob: "gems/relaton-oiml/*.gemspec"

# pubid v2 (with OIML support) parses primary docids into structured
# identifiers for the pubid_class-based index-v2.yaml. Tracks the
# rt-new-lutaml-model branch until pubid v2 is released; lutaml-model follows
# main to match pubid's serialization (relaton-bib allows ~> 0.8.0).
gem "pubid", git: "https://github.com/metanorma/pubid.git",
             branch: "rt-new-lutaml-model"
gem "lutaml-model", git: "https://github.com/lutaml/lutaml-model.git",
                    branch: "main"

gem "thor",              "~> 1.3"
gem "nokogiri"
gem "net-http-persistent"
gem "activesupport", require: false   # String#squish for translation parsing

group :development, :test do
  gem "rspec", "~> 3.13"
  gem "webmock"
end



