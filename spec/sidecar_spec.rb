# frozen_string_literal: true

# examples/sidecar.json is not written by hand and not written for this: it is
# what `@fastify/swagger` prints for a running service, checked in exactly as
# the service emits it. Everything the generator has to cope with in a document
# nobody wrote is true of it at once — no operationId, no components, no
# servers — and the two hand-written examples cannot stand in for that, because
# they were written by somebody who knew what the generator does with them.
#
# The assertions here go through Client.operations rather than through type
# names, since the names of deduplicated models are not settled.
RSpec.describe "a document a server wrote about itself" do
  subject(:operations) { Sidecar::Client.operations }

  # The verb and the path are the whole of what there is to name a method with.
  it "names its methods for the routes they call" do
    expect(operations.keys).to include(:post_didcomm_pack_encrypted, :get_health, :post_did_peer_4_create)
  end

  it "keeps a path parameter from colliding with the collection it hangs off" do
    expect(operations.keys.grep(/resolve/)).to contain_exactly(:post_did_resolve, :post_did_peer_4_resolve_short)
  end

  # With no components, the same schema is written out again under every
  # operation that uses it. Identity rather than name: which of the eight
  # places an error body appears gets to name the type is exactly what is
  # unsettled about it, but that they are one type is the point.
  it "gives one type to a schema its document repeats" do
    errors = operations.values.flat_map { _1[:errors].values }.uniq

    expect(errors.size).to be < operations.size
    expect(operations[:post_did_didcomm_doc][:body]).to equal operations[:post_did_resolve][:body]
  end

  it "does not merge two schemas that only look alike" do
    expect(operations[:post_didcomm_pack_signed][:into])
      .not_to equal operations[:post_didcomm_pack_encrypted][:into]
  end

  # A sidecar publishes no address, so the application has to supply one. The
  # generator emits `server nil` rather than an empty string, and the error
  # names the class instead of surfacing later from inside URI.
  it "leaves the address to the application" do
    expect(Sidecar::Client.server).to be_nil
    expect { Sidecar::Client.new }.to raise_error(Keiyaku::Error, /has no server declared/)
    expect(Sidecar::Client.new(base_url: "http://127.0.0.1:3100").base_url).to eq "http://127.0.0.1:3100"
  end

  # The constructs it would not translate faithfully. Each is a note rather
  # than a refusal — the operation still works and the field is just :any —
  # so what this pins is that the fields around them are unaffected.
  it "types what it cannot translate as :any, and only that" do
    options = Sidecar::PostDidcommPackEncryptedBodyOptions
    attachments = Sidecar::PostDidcommPackEncryptedBodyMessageAttachments

    # An array of tuples. A tuple is fixed-length and heterogeneous, which one
    # element type cannot describe, so the inner one degrades and the array
    # around it does not.
    expect(options.types[:forward_headers]).to eq [[:any]]
    expect(options.types[:protect_sender]).to eq :bool

    # anyOf with nothing to dispatch on.
    expect(attachments.types[:data]).to eq :any
    expect(attachments.types[:media_type]).to eq String
  end

  # The property that named the bug this document found: a DIDComm message has
  # one called `from`, which as a keyword argument would have taken the place
  # of Keiyaku.model's own `from:` option and left the field out of the class.
  it "keeps a property named like one of the model's own options" do
    message = Sidecar::PostDidcommPackEncryptedBodyMessage

    expect(message.members).to include(:from, :to, :type, :body)
    expect(message.types[:from]).to eq String
    # Already snake_case in the document, so nothing is mapped to camelCase.
    expect(message.json_names[:created_time]).to eq "created_time"
  end
end
