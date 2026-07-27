# frozen_string_literal: true

# Drives the generated client against a real socket, so the whole path is
# exercised: signature, serialization, transport, decoding, error mapping.

$LOAD_PATH.unshift File.expand_path("../lib", __dir__)
require "socket"
require "stringio"
require "tempfile"
require "tmpdir"
require "uri"
require "json"
require_relative "../examples/petstore/client"

PASS = []
FAIL = []

def check(name)
  result = yield
  result ? PASS << name : FAIL << "#{name}: returned #{result.inspect}"
rescue StandardError => e
  FAIL << "#{name}: #{e.class}: #{e.message}"
end

PET = {
  "id" => 5, "name" => "Kaya", "status" => "available",
  "photoUrls" => ["https://example.test/kaya.jpg"],
  "category" => { "id" => 1, "name" => "Dogs" },
  "tags" => [{ "id" => 7, "name" => "good" }],
  "wingspan" => "a field this client has never heard of"
}.freeze

WIDGET = ->(id) { { "id" => id, "created_at" => "2026-07-26T10:00:00Z" } }
EVENTS = (1..5).map { { "kind" => "retired", "id" => _1 } }.freeze

# --- a server that records what it was sent -----------------------------------

server = TCPServer.new("127.0.0.1", 0)
PORT = server.addr[1]
SEEN = Queue.new

Thread.new do
  loop do
    socket = server.accept
    request_line = socket.gets
    verb, target, = request_line.split
    headers = {}
    while (line = socket.gets) && line != "\r\n"
      key, value = line.split(": ", 2)
      headers[key.downcase] = value.to_s.strip
    end
    body = headers["content-length"] ? socket.read(headers["content-length"].to_i) : nil
    SEEN << { verb:, target:, headers:, body: }
    query = URI.decode_www_form(target.split("?", 2)[1].to_s).to_h

    status, payload, extra =
      case [verb, target.split("?").first]
      in ["GET", "/api/v3/pet/findByStatus"] then [200, [PET]]
      in ["GET", "/api/v3/pet/5"] then [200, PET]
      in ["GET", "/api/v3/pet/999"] then [404, { "code" => 404, "type" => "error", "message" => "Pet not found" }]
      in ["GET", "/api/v3/store/inventory"] then [200, { "available" => 12, "sold" => 3 }]
      in ["GET", "/api/v3/user/login"] then [200, "session-token"]
      in ["POST", "/api/v3/pet"] then [200, JSON.parse(body)]
      in ["DELETE", "/api/v3/pet/5"] then [200, nil]
      in ["GET", "/api/v3/pet/findByTags"] then [200, []]
      in ["POST", "/api/v3/pet/5/uploadImage"] then [200, { "code" => 200, "type" => "ok", "message" => "stored" }]
      in ["GET", "/v1/widgets/1"] then
        [200, { "id" => 1, "created_at" => "2026-07-26T10:00:00Z",
                "labels" => { "env" => "prod" }, "retired" => false }]
      in ["GET", "/v1/widgets/2"] then [500, { "detail" => "boom", "trace_id" => "t-1" }]
      in ["POST", "/v1/widgets"] then [422, { "detail" => "that id is taken", "source" => "id" }]
      in ["GET", "/v1/widgets/1/events"] then
        [200, [{ "kind" => "created",
                 "widget" => { "id" => 1, "created_at" => "2026-07-26T10:00:00Z" } },
               { "kind" => "retired", "id" => 1, "reason" => "end of life" }]]
      in ["GET", "/v1/widgets/3/events"] then [200, [{ "kind" => "exploded" }]]
      in ["POST", "/v1/widgets/1/photo"] then [200, WIDGET.(1)]

      # Three pages by offset, the last one short.
      in ["GET", "/v1/widgets/7/events"] then
        [200, EVENTS[query["offset"].to_i, (query["limit"] || EVENTS.size).to_i] || []]

      # Three pages by cursor, the last one without a next.
      in ["GET", "/v1/widgets/search"] then
        page = query["cursor"].to_i
        envelope = { "items" => [WIDGET.(page + 1)] }
        envelope["next_cursor"] = (page + 1).to_s if page < 2
        [200, envelope]

      # Two pages by Link header. The capital L is the point.
      in ["GET", "/v1/widgets/feed"] then
        if query["page"] == "2"
          [200, [WIDGET.(2)]]
        else
          [200, [WIDGET.(1)],
           { "Link" => %(<http://127.0.0.1:#{PORT}/v1/widgets/feed?page=2>; rel="next") }]
        end
      else [500, { "message" => "unexpected #{verb} #{target}" }]
      end

    encoded = payload.nil? ? "" : JSON.generate(payload)
    socket.print "HTTP/1.1 #{status}\r\nContent-Type: application/json\r\n" \
                 "#{extra.to_h.map { |k, v| "#{k}: #{v}\r\n" }.join}" \
                 "Content-Length: #{encoded.bytesize}\r\nConnection: close\r\n\r\n#{encoded}"
    socket.close
  end
end

client = Petstore::Client.new(base_url: "http://127.0.0.1:#{PORT}/api/v3", auth: "secret-key")

# --- decoding -----------------------------------------------------------------

pet = client.get_pet_by_id(5)
SEEN.pop

check("casts into the generated Data type") { pet.is_a?(Petstore::Pet) && pet.frozen? }
check("maps camelCase onto snake_case") { pet.photo_urls == ["https://example.test/kaya.jpg"] }
check("casts nested models") { pet.category == Petstore::Category.new(id: 1, name: "Dogs") }
check("casts arrays of models") { pet.tags == [Petstore::Tag.new(id: 7, name: "good")] }
check("ignores unknown response fields") { !pet.respond_to?(:wingspan) }
check("supports pattern matching") { (pet in { name: String, category: { name: "Dogs" } }) }
check("supports #with") { pet.with(name: "Nori").name == "Nori" && pet.name == "Kaya" }

check("decodes an array response") { client.find_pets_by_status(status: "available") in [Petstore::Pet] }
SEEN.pop
check("decodes a map response") { client.get_inventory == { "available" => 12, "sold" => 3 } }
SEEN.pop
check("decodes a scalar response") { client.login_user(username: "ada", password: "x") == "session-token" }
SEEN.pop

# --- requests -----------------------------------------------------------------

client.add_pet(Petstore::Pet.new(name: "Nori", photo_urls: ["https://example.test/n.jpg"], status: "pending"))
sent = SEEN.pop
check("serializes the body back to camelCase") { JSON.parse(sent[:body]).key?("photoUrls") }
check("omits fields left nil") { !JSON.parse(sent[:body]).key?("id") }
check("sets Content-Type") { sent[:headers]["content-type"] == "application/json" }
check("sends the security scheme's header") { sent[:headers]["api_key"] == "secret-key" }

client.find_pets_by_status(status: "available")
check("serializes query parameters") { SEEN.pop[:target].end_with?("/pet/findByStatus?status=available") }

client.find_pets_by_tags(tags: %w[good soft])
check("explodes array query parameters") { SEEN.pop[:target].end_with?("?tags=good&tags=soft") }

client.delete_pet(5, api_key: "override")
check("sends header parameters") { SEEN.pop[:headers]["api_key"] == "override" }

# --- signatures ---------------------------------------------------------------

check("path parameters are positional") do
  Petstore::Client.instance_method(:get_pet_by_id).parameters == [%i[req pet_id]]
end
check("required query parameters are required keywords") do
  Petstore::Client.instance_method(:find_pets_by_status).parameters == [%i[keyreq status]]
end
check("optional query parameters have defaults") do
  Petstore::Client.instance_method(:update_pet_with_form).parameters ==
    [%i[req pet_id], %i[key name], %i[key status]]
end
check("wrong arity raises immediately") do
  client.get_pet_by_id rescue $!.is_a?(ArgumentError)
end

# --- failure ------------------------------------------------------------------

check("maps 4xx to an exception") do
  client.get_pet_by_id(999)
rescue Keiyaku::ClientError => e
  SEEN.pop
  # This spec documents no schema for 404, so the body stays undecoded.
  e.status == 404 && e.parsed["message"] == "Pet not found"
end

check("sends a binary body untouched") do
  response = client.upload_file(5, "\x89PNG\r\n".b, additional_metadata: "paw")
  sent = SEEN.pop
  sent[:headers]["content-type"] == "application/octet-stream" &&
    sent[:body].b == "\x89PNG\r\n".b &&
    sent[:target].include?("additionalMetadata=paw") &&
    response.is_a?(Petstore::ApiResponse)
end

check("a bad payload names the field") do
  Petstore::Pet.cast({ "name" => "x", "photoUrls" => [], "id" => "not-a-number" })
rescue Keiyaku::CastError => e
  e.message.include?("Petstore::Pet.id")
end

check("a missing required field is caught") do
  Petstore::Pet.cast({ "id" => 1 })
rescue Keiyaku::CastError => e
  e.message.include?("missing required field")
end

# --- the adapter seam ---------------------------------------------------------

# An adapter returns headers however its HTTP library spells them. Net::HTTP
# happens to downcase; nothing else has to, so the runtime does it.
shouty = Object.new
def shouty.call(_verb, _uri, _headers, _body)
  [200, { "Content-Type" => ["application/json"] }, JSON.generate(PET)]
end

check("does not depend on an adapter's header casing") do
  Petstore::Client.new(base_url: "http://unused.test", adapter: shouty).get_pet_by_id(5).name == "Kaya"
end

# The optional adapters, over the same socket as everything else. Neither gem
# is a dependency, so a missing one is skipped rather than failed.
{ "faraday" => :FaradayAdapter, "http" => :HTTPAdapter }.each do |gem_name, adapter|
  begin
    require "keiyaku/adapters/#{gem_name}"
  rescue LoadError
    puts "  skipped the #{gem_name} adapter: gem not installed"
    next
  end

  on = Petstore::Client.new(base_url: "http://127.0.0.1:#{PORT}/api/v3", auth: "secret-key",
                            adapter: Keiyaku.const_get(adapter).new)

  check("#{gem_name}: decodes a response") do
    pet = on.get_pet_by_id(5)
    SEEN.pop
    pet.name == "Kaya"
  end

  check("#{gem_name}: sends the body and the credentials") do
    on.add_pet(Petstore::Pet.new(name: "Nori", photo_urls: []))
    sent = SEEN.pop
    JSON.parse(sent[:body])["name"] == "Nori" && sent[:headers]["api_key"] == "secret-key"
  end

  check("#{gem_name}: maps 4xx to an exception") do
    on.get_pet_by_id(999)
  rescue Keiyaku::ClientError => e
    SEEN.pop
    e.status == 404
  end
end

# --- a second, unrelated spec -------------------------------------------------

require_relative "../examples/widgets/client"
widgets = Widgets::Client.new(base_url: "http://127.0.0.1:#{PORT}/v1", auth: "t0ken")

widget = widgets.get_widget(1)
sent = SEEN.pop
check("keeps a JSON name that is already snake_case") { widget.created_at.is_a?(Time) }
check("coerces date-time to Time") { widget.created_at.utc.hour == 10 }
check("decodes a map property") { widget.labels == { "env" => "prod" } }
check("decodes booleans") { widget.retired == false }
check("sends bearer credentials") { sent[:headers]["authorization"] == "Bearer t0ken" }

check("casts a documented 4xx body") do
  widgets.create_widget(Widgets::Widget.new(id: 1, created_at: Time.now))
rescue Keiyaku::ClientError => e
  SEEN.pop
  e.parsed.is_a?(Widgets::Problem) && e.parsed.detail == "that id is taken" &&
    # anyOf with no discriminator: typed :any, so it arrives undecoded.
    e.parsed.source == "id"
end

# --- unions -------------------------------------------------------------------

events = widgets.list_events(1)
SEEN.pop

check("casts each variant of a discriminated union") do
  events in [Widgets::WidgetCreated(widget: Widgets::Widget(id: 1)),
             Widgets::WidgetRetired(reason: "end of life")]
end

check("an unknown discriminator is an error, not a guess") do
  widgets.list_events(3)
rescue Keiyaku::CastError => e
  SEEN.pop
  e.message.include?('kind="exploded"')
end

# --- multipart ----------------------------------------------------------------

check("encodes a multipart body") do
  widgets.upload_photo(1, Widgets::UploadPhotoBody.new(
    file: Keiyaku::Upload.new(StringIO.new("\x89PNG\r\n".b), filename: "kaya.png", content_type: "image/png"),
    caption: "a dog", tags: %w[dog good]
  ))
  sent = SEEN.pop
  boundary = sent[:headers]["content-type"][/boundary=(.+)/, 1]

  sent[:headers]["content-type"].start_with?("multipart/form-data; boundary=keiyaku-") &&
    sent[:body].include?(%(Content-Disposition: form-data; name="file"; filename="kaya.png")) &&
    sent[:body].include?("Content-Type: image/png") &&
    sent[:body].include?("\x89PNG\r\n".b) &&
    sent[:body].include?(%(name="caption"\r\n\r\na dog)) &&
    # An array property is one part per element, not one comma-joined part.
    sent[:body].scan(/name="tags"/).size == 2 &&
    sent[:body].end_with?("--#{boundary}--\r\n")
end

check("wraps a bare IO as a file part, and omits what was left nil") do
  spec = File.expand_path("../examples/widgets.yaml", __dir__)
  widgets.upload_photo(1, Widgets::UploadPhotoBody.new(file: File.open(spec)))
  sent = SEEN.pop
  sent[:body].include?(%(filename="widgets.yaml")) &&
    sent[:body].scan("Content-Disposition").size == 1
end

check("multipart takes the body positionally, like any other") do
  Widgets::Client.instance_method(:upload_photo).parameters == [%i[req id], %i[req body]]
end

# --- pagination ---------------------------------------------------------------

check("an enumerator makes only the requests it is asked for") do
  first = widgets.list_events_each(7).lazy.first(1)
  SEEN.pop
  first.map(&:id) == [1] && SEEN.empty?
end

check("walks offset pages until one comes back short") do
  ids = widgets.list_events_each(7).map(&:id)
  requests = 3.times.map { SEEN.pop[:target] }
  ids == [1, 2, 3, 4, 5] && requests.all? { _1.include?("limit=2") } &&
    requests.map { _1[/offset=(\d+)/, 1] } == %w[0 2 4]
end

check("sends no cursor on the first request, then the one it was given") do
  ids = widgets.search_widgets_each(q: "kaya").map(&:id)
  requests = 3.times.map { SEEN.pop[:target] }
  ids == [1, 2, 3] && !requests[0].include?("cursor=") &&
    requests[1].include?("cursor=1") && requests[2].include?("cursor=2")
end

check("digs the items out of an envelope") do
  widgets.search_widgets(q: "kaya") in Widgets::SearchWidgetsResult(next_cursor: "1")
ensure
  SEEN.pop
end

check("follows a Link header until there is no next") do
  ids = widgets.widget_feed_each.map(&:id)
  2.times { SEEN.pop }
  ids == [1, 2]
end

check("takes a block as well as returning an enumerator") do
  seen = []
  widgets.widget_feed_each { seen << _1.id }
  2.times { SEEN.pop }
  seen == [1, 2]
end

# --- what the generator refuses to build --------------------------------------

require "keiyaku/emitter"

def generate(yaml)
  Tempfile.create(["spec", ".yaml"]) do |file|
    file.write(yaml)
    file.flush
    emitter = Keiyaku::Emitter.new(file.path, namespace: "Refused")
    Dir.mktmpdir { |dir| emitter.emit(dir) }
    emitter
  end
end

BAD_HINT = <<~YAML
  openapi: 3.1.0
  info: { title: Refused, version: "1" }
  servers: [{ url: "https://refused.test" }]
  paths:
    /things:
      get:
        operationId: listThings
        parameters:
          - { name: limit, in: query, schema: { type: integer } }
        x-keiyaku-paginate: { by: offset, param: skip, size: limit }
        responses: { "200": { description: ok } }
YAML

check("refuses a paginate hint naming a parameter the operation lacks") do
  generate(BAD_HINT).refusals.first.reason.include?(%(param "skip" is not a query parameter))
end

check("refuses a pagination strategy it does not implement") do
  generate(BAD_HINT.sub("by: offset, param: skip", "by: seek, param: limit"))
    .refusals.first.reason.include?("unknown strategy")
end

check("casts a default error body, and 5xx is a ServerError") do
  widgets.get_widget(2)
rescue Keiyaku::ServerError => e
  SEEN.pop
  e.parsed.is_a?(Widgets::Problem) && e.parsed.trace_id == "t-1"
end

check("refuses a deepObject parameter") do
  widgets.list_widgets
rescue Keiyaku::Unsupported => e
  e.message.include?("deepObject")
end

puts "#{PASS.size} passed, #{FAIL.size} failed"
FAIL.each { puts "  FAIL #{_1}" }
exit(FAIL.empty? ? 0 : 1)
