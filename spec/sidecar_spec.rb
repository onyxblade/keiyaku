# frozen_string_literal: true

# examples/sidecar.json is the same service as examples/sidecar-inline.json,
# after it gave its shared shapes a `$id`. Nothing about the routes changed —
# ten operations, no operationId, no servers, still printed by the server rather
# than written for this — so what the two documents differ in is only whether
# the shapes they repeat are named, which makes this the one pair here that says
# what naming a schema is worth.
#
# It is worth 71 models against 32: the shape a DIDComm message has is written
# once and every operation refers to it, where before each of the four carried
# its own copy and got its own type.
RSpec.describe "a document that names its shared shapes" do
  subject(:operations) { Sidecar::Client.operations }

  # Where the document names a type, the name is its own — not the position the
  # generator reached it from, which is all it has to go on otherwise.
  it "takes its type names from the document" do
    expect(Sidecar.constants).to include(
      :Message, :Attachment, :DIDDoc, :VerificationMethod, :Service, :Secret,
      :ErrorResponse, :DIDResolutionResult
    )
  end

  # The whole point of the change in the service: one message type, so a caller
  # can build a message and pack it three ways. Four copies of the schema were
  # four types, and no value could be passed to more than one of them.
  it "gives every operation that takes a message the same message type" do
    bodies = %i[
      post_didcomm_pack_encrypted post_didcomm_pack_signed post_didcomm_pack_plaintext
    ].map { operations[_1][:body].types[:message] }

    expect(bodies.uniq).to eq [Sidecar::Message]
    # And what comes back out of an envelope is the same type as what went in.
    expect(operations[:post_didcomm_unpack][:into].types[:message]).to equal Sidecar::Message
  end

  it "gives every operation that takes a pinned document or a secret the same types" do
    body = operations[:post_didcomm_pack_encrypted][:body]

    expect(body.types[:did_docs]).to eq [Sidecar::DIDDoc]
    expect(body.types[:secrets]).to eq [Sidecar::Secret]
    # The resolver hands back the same DIDDoc the pack endpoints accept, which
    # is the pair of operations a caller actually uses together.
    expect(operations[:post_did_didcomm_doc][:into].types[:did_doc]).to equal Sidecar::DIDDoc
  end

  # Six operations describe their 400 with the same named schema, so there is
  # one class to rescue rather than one per operation.
  it "gives every operation that fails the same error type" do
    errors = operations.values.flat_map { _1[:errors].values }

    expect(errors.uniq).to contain_exactly(Sidecar::ErrorResponse, Sidecar::DIDResolutionResult)
  end

  # sidecar_inline_spec.rb asserts the opposite of this, and both are right.
  # There, /did/resolve's 400 is a schema of its own that happens to have the
  # shape of its 200, and matching the two up by structure would hand a caller
  # rescuing the error a type whose name said the call had succeeded. Here the
  # document says outright that both are DIDResolutionResult — the W3C result
  # carries its own error field — so one type is what it describes, and the name
  # claims nothing either way.
  it "lets an operation say its error is its result, where the document says so" do
    op = operations[:post_did_resolve]

    expect(op[:into]).to equal Sidecar::DIDResolutionResult
    expect(op[:errors]).to eq(400 => Sidecar::DIDResolutionResult, 404 => Sidecar::DIDResolutionResult)
  end

  # Naming the shared shapes does not change the rule for the rest: a schema the
  # document still writes inline is named for where it was written, and one
  # nested inside a named schema is named for that schema rather than for
  # whichever operation reached it first.
  it "still names by position everything the document left unnamed" do
    expect(operations[:post_didcomm_pack_encrypted][:body].types[:options])
      .to equal Sidecar::PostDidcommPackEncryptedBodyOptions
    expect(Sidecar::DIDResolutionResult.types[:did_resolution_metadata])
      .to equal Sidecar::DIDResolutionResultDidResolutionMetadata
  end

  # What it cannot translate is now said once per shape instead of once per
  # copy, which is the same four notes the inline document spreads over
  # thirteen.
  it "types what it cannot translate as :any, and only that" do
    expect(Sidecar::Attachment.types[:data]).to eq :any
    expect(Sidecar::Attachment.types[:media_type]).to eq String
    expect(Sidecar::Service.types[:service_endpoint]).to eq :any
    expect(Sidecar::Service.types[:id]).to eq String
    expect(Sidecar::PostDidcommPackEncryptedBodyOptions.types[:forward_headers]).to eq [[:any]]
  end

  # A DIDComm message has a property called `from`, which as a keyword argument
  # would have taken the place of Keiyaku.model's own `from:` option.
  it "keeps a property named like one of the model's own options" do
    expect(Sidecar::Message.members).to include(:from, :to, :type, :body)
    expect(Sidecar::Message.types[:from]).to eq String
    # The service's own fields are camelCase and the convention maps them; the
    # ones DIDComm itself spells snake_case are mapped back by name.
    expect(Sidecar::Message.json_names[:created_time]).to eq "created_time"
    expect(operations[:post_didcomm_pack_encrypted][:into].json_names[:packed_message])
      .to eq "packedMessage"
  end
end
