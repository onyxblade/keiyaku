# frozen_string_literal: true

# Loads the runtime, which is all an application needs: generated clients
# require "keiyaku/runtime" directly. The generator is a separate file that
# only the `keiyaku` executable pulls in, so nothing that merely calls an API
# ever loads it.
require_relative "keiyaku/runtime"
