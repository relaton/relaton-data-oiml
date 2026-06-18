# frozen_string_literal: true

# Test infrastructure — adds lib/ to the load path so `require "oiml_fetcher"`
# resolves. Library code itself never does this.
repo_root = File.expand_path("..", __dir__)
$LOAD_PATH.unshift File.join(repo_root, "lib")

require "oiml_fetcher"
require "webmock/rspec"
WebMock.disable_net_connect!(allow_localhost: true)

RSpec.configure do |config|
  config.expect_with :rspec do |expectations|
    expectations.include_chain_clauses_in_custom_matcher_descriptions = true
  end

  config.mock_with :rspec do |mocks|
    mocks.verify_partial_doubles = true
  end

  config.shared_context_metadata_behavior = :apply_to_host_groups
  config.filter_run_when_matching :focus
  config.example_status_persistence_file_path = "spec/examples.txt"
  config.disable_monkey_patching!
  config.warnings = true
  config.default_formatter = "doc" if config.files_to_run.one?
  config.profile_examples = 10
  config.order = :random
  Kernel.srand config.seed
end
