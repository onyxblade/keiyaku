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
  # operation that uses it — the error body appears in eight places, and eight
  # of these routes take a structurally identical request. Each copy is named
  # after the operation it was written under, so the names are the settled part
  # rather than the unsettled one: no operation is handed a type called after a
  # different operation, which is the only name the generator could have picked
  # and the only one that records where it walked rather than what it read.
  it "names every type after the operation it was written under" do
    operations.each do |name, op|
      expected = "Sidecar::#{name.to_s.split("_").map(&:capitalize).join}"
      types = { "Body" => op[:body], "Result" => op[:into] }
        .merge(op[:errors].transform_keys { "Error" })

      types.each do |suffix, type|
        next unless type.is_a?(Class)

        expect(type.name).to eq "#{expected}#{suffix}"
      end
    end
  end

  # The worst of what naming a type by structural match produced: this
  # operation's 400 body happens to have the same shape as its 200 body, so the
  # error was typed as the result, and a caller rescuing it got a value whose
  # class said it had succeeded.
  it "does not hand an operation its result type as its error type" do
    op = operations[:post_did_resolve]

    expect(op[:errors].values.uniq).to eq [Sidecar::PostDidResolveError]
    expect(op[:errors].values).not_to include op[:into]
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
