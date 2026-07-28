# frozen_string_literal: true

# The same service twice, before and after it named its shared shapes. The two
# clients are called identically here on purpose: what the naming rule changes
# is what the types are called, not what a caller has to write.

named = Sidecar::Client.new(base_url: "https://sidecar.test")
anonymous = SidecarInline::Client.new(base_url: "https://sidecar.test")

named.get_health.status.upcase
anonymous.get_health.status.upcase

# A schema the document named is that name; one it did not is named for the
# operation it was written under. Both resolve to a model with the same fields.
resolved = named.post_did_resolve(Sidecar::PostDidResolveBody.new(did: "did:example:1"))
resolved.did_document_metadata.fetch("deactivated", nil)
resolved.did_resolution_metadata.content_type&.length

inline = anonymous.post_did_resolve(SidecarInline::PostDidResolveBody.new(did: "did:example:1"))
inline.did_document_metadata.fetch("deactivated", nil)
inline.did_resolution_metadata.content_type&.length

# Nesting survives the trip: a required field of a required field is reachable
# without a nil check, and an optional one is not.
message = Sidecar::Message.new(id: "1", typ: "application/didcomm-plain+json", type: "https://example.test/1", body: {})
packed = named.post_didcomm_pack_encrypted(
  Sidecar::PostDidcommPackEncryptedBody.new(
    message: message,
    to: "did:example:2",
    from: "did:example:1",
    options: Sidecar::PostDidcommPackEncryptedBodyOptions.new(protect_sender: true, forward: false)
  )
)
packed.packed_message.length
packed.metadata.to_kids.each { |kid| kid.length }
packed.metadata.messaging_service&.service_endpoint&.length

# The document let this schema carry properties it did not name, so the model
# is open: `new` takes them and `[]` reads them back as `untyped`.
extra = Sidecar::Message.new(id: "2", typ: "x", type: "y", body: {}, custom_header: "kept")
extra[:custom_header]
extra["custom_header"]
extra.to_json_hash.fetch("id")
