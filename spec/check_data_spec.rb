# frozen_string_literal: true

require "open3"

# Regression guard for check_data.rb: custom OIML `ext` fields that the relaton
# model drops on round-trip must be listed in CUSTOM_EXT_KEYS so the validator
# restores them before comparison. The `high_priority` / `high_priority_source`
# fields were added to data files without being added to that list, which broke
# the round-trip check in CI.
RSpec.describe "check_data.rb" do
  repo_root = File.expand_path("..", __dir__)
  script = File.join(repo_root, "check_data.rb")
  fixture = File.join(repo_root, "spec/fixtures/check_data/high_priority.yaml")

  it "round-trips a record carrying high_priority ext fields" do
    stdout, stderr, status = Open3.capture3(
      "bundle", "exec", "ruby", script, fixture, chdir: repo_root
    )

    expect(stdout).to include("round-trip cleanly"),
                      -> { "check_data.rb reported a mismatch:\n#{stdout}\n#{stderr}" }
    expect(status).to be_success
  end
end
