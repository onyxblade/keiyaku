# frozen_string_literal: true

source "https://rubygems.org"

gemspec

gem "rake", "~> 13.0"
gem "rbs", "~> 4.0"
gem "rspec", "~> 3.13"
gem "steep", "~> 2.0"

# Only so the optional adapters in lib/keiyaku/adapters are covered by the
# tests. The gem itself depends on neither, and the tests skip whichever is
# missing rather than failing.
gem "faraday", "~> 2.0"
gem "http", "~> 5.0"
