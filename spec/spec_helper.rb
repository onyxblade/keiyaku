# frozen_string_literal: true

$LOAD_PATH.unshift File.expand_path("../lib", __dir__)

require "json"
require "stringio"
require "tempfile"
require "tmpdir"

# The checked-in generated clients, loaded as an application would load them.
# `rake` regenerates them first, so the specs run against current output.
require_relative "../examples/petstore/client"
require_relative "../examples/widgets/client"

require_relative "support/test_server"
require_relative "support/clients"

RSpec.configure do |config|
  config.disable_monkey_patching!
  config.expect_with(:rspec) { _1.syntax = :expect }
  config.filter_run_when_matching :focus
  config.example_status_persistence_file_path = "tmp/rspec-status"

  config.order = :random
  Kernel.srand config.seed

  config.include Clients

  config.before(:suite) { TestServer.start }

  # Every example asserts on the requests it made itself, so it starts with
  # none outstanding. This is what makes running in random order safe.
  config.before { TestServer.requests.clear }
end
