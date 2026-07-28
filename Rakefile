# frozen_string_literal: true

require "bundler/gem_tasks"
require "rspec/core/rake_task"

# The document to generate from, and the module to generate into. The output
# directory is the document's name without its extension.
EXAMPLES = {
  "examples/petstore.yaml" => "Petstore",
  "examples/widgets.yaml" => "Widgets",
  "examples/sidecar.json" => "Sidecar",
  "examples/sidecar-inline.json" => "SidecarInline"
}.freeze

def output_for(document) = document.sub(/\.\w+\z/, "")

desc "Regenerate the checked-in example clients"
task :examples do
  EXAMPLES.each do |document, mod|
    sh "ruby -Ilib exe/keiyaku #{document} --module #{mod} --out #{output_for(document)}"
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
  includes = ["sig", *EXAMPLES.keys.map { output_for(_1) }]
  sh "rbs #{includes.map { "-I #{_1}" }.join(" ")} validate"
end

desc "Type-check calling code against the generated RBS"
task :steep do
  sh "steep check"
end

desc "Drive the generated clients against a real socket"
RSpec::Core::RakeTask.new(:spec)

task default: %i[examples rbs steep spec]
