# frozen_string_literal: true

require "bundler/gem_tasks"
require "rspec/core/rake_task"

EXAMPLES = { "petstore" => "Petstore", "widgets" => "Widgets" }.freeze

desc "Regenerate the checked-in example clients"
task :examples do
  EXAMPLES.each do |name, mod|
    sh "ruby -Ilib exe/keiyaku examples/#{name}.yaml --module #{mod} --out examples/#{name}"
  end
end

desc "Fail if the checked-in examples are stale"
task :verify do
  Rake::Task[:examples].invoke
  sh "git diff --quiet --exit-code examples" do |ok, _|
    abort "examples are out of date; run `rake examples` and commit the result" unless ok
  end
end

desc "Check the generated RBS resolves against the runtime's own signatures"
task :rbs do
  includes = ["sig", *EXAMPLES.keys.map { "examples/#{_1}" }]
  sh "rbs #{includes.map { "-I #{_1}" }.join(" ")} validate"
end

desc "Drive the generated clients against a real socket"
RSpec::Core::RakeTask.new(:spec)

task default: %i[examples rbs spec]
