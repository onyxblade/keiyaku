# frozen_string_literal: true

# `rake rbs` asks whether the generated signatures resolve. This asks the
# harder question: whether they are true. The files under `checks` are calling
# code that never runs — Steep reads them against the RBS the generator emitted
# for each example, so a signature that has drifted from the client beside it
# fails here rather than in somebody's editor.
target :checks do
  signature "sig", *Dir.glob("examples/*/")

  check "checks"

  library "time", "json"
end
