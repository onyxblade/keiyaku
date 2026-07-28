# frozen_string_literal: true

require_relative "lib/keiyaku/version"

Gem::Specification.new do |spec|
  spec.name = "keiyaku"
  spec.version = Keiyaku::VERSION
  spec.authors = ["merely"]
  spec.email = ["git@merely.ca"]

  spec.summary = "OpenAPI clients as a table of operations, not a generated codebase."
  spec.description = <<~TEXT
    Generates Ruby clients from OpenAPI documents that carry only what is
    specific to one API — an operation table and the schema fields. Transport,
    parameter serialization, casting and error mapping live in a shared
    runtime, so a nineteen-operation client is about seventy lines. A schema
    becomes a frozen value type with RBS emitted beside it, so terse Ruby
    costs nothing in tooling. Constructs it cannot translate faithfully are
    refused at generation time rather than emitted as plausible guesses.
  TEXT
  spec.homepage = "https://github.com/onyxblade/keiyaku"
  spec.license = "MIT"
  spec.required_ruby_version = ">= 3.2" # Data.define

  # No homepage_uri: spec.homepage already is it, and setting both makes
  # rubygems.org drop one and warn about it at build time.
  spec.metadata["source_code_uri"] = spec.homepage
  spec.metadata["changelog_uri"] = "#{spec.homepage}/blob/main/CHANGELOG.md"
  spec.metadata["rubygems_mfa_required"] = "true"

  # Globbed rather than shelled out to git, so building from an unpacked
  # tarball produces the same gem. Examples and tests stay in the repo.
  spec.files = Dir[
    "lib/**/*.rb",
    "sig/**/*.rbs",
    "exe/*",
    "{README,DESIGN,CHANGELOG}.md",
    "LICENSE.txt"
  ]
  spec.require_paths = ["lib"]
  spec.bindir = "exe"
  spec.executables = ["keiyaku"]

  # No runtime dependencies, and none are wanted: a generated client should not
  # drag an HTTP stack into an application that already has one. The default
  # adapter is net/http from the standard library; pass `adapter:` to swap it.
end
