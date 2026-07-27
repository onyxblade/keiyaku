# frozen_string_literal: true

EXAMPLES = { "petstore" => "Petstore", "widgets" => "Widgets" }.freeze

desc "Regenerate the checked-in example clients"
task :examples do
  EXAMPLES.each do |name, namespace|
    sh "ruby bin/generate examples/#{name}.yaml #{namespace} examples/#{name}"
  end
end

desc "Fail if the checked-in examples are stale"
task :verify do
  Rake::Task[:examples].invoke
  sh "git diff --quiet --exit-code examples" do |ok, _|
    abort "examples are out of date; run `rake examples` and commit the result" unless ok
  end
end

desc "Check the generated RBS parses"
task :rbs do
  sh "rbs parse #{EXAMPLES.keys.map { "examples/#{_1}/#{_1}.rbs" }.join(" ")}"
end

desc "Drive the generated clients against a real socket"
task :test do
  sh "ruby test/e2e.rb"
end

task default: %i[examples rbs test]
