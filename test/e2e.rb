# frozen_string_literal: true

# Drives the generated client against a real socket, so the whole path is
# exercised: signature, serialization, transport, decoding, error mapping.

$LOAD_PATH.unshift File.expand_path("../lib", __dir__)
require "socket"
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

    status, payload =
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
      in ["POST", "/v1/widgets"] then [422, { "detail" => "that id is taken" }]
      else [500, { "message" => "unexpected #{verb} #{target}" }]
      end

    encoded = payload.nil? ? "" : JSON.generate(payload)
    socket.print "HTTP/1.1 #{status}\r\nContent-Type: application/json\r\n" \
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
rescue OpenAPI::ClientError => e
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
rescue OpenAPI::CastError => e
  e.message.include?("Petstore::Pet.id")
end

check("a missing required field is caught") do
  Petstore::Pet.cast({ "id" => 1 })
rescue OpenAPI::CastError => e
  e.message.include?("missing required field")
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
rescue OpenAPI::ClientError => e
  SEEN.pop
  e.parsed.is_a?(Widgets::Problem) && e.parsed.detail == "that id is taken"
end

check("casts a default error body, and 5xx is a ServerError") do
  widgets.get_widget(2)
rescue OpenAPI::ServerError => e
  SEEN.pop
  e.parsed.is_a?(Widgets::Problem) && e.parsed.trace_id == "t-1"
end

check("refuses a deepObject parameter") do
  widgets.list_widgets
rescue OpenAPI::Unsupported => e
  e.message.include?("deepObject")
end

puts "#{PASS.size} passed, #{FAIL.size} failed"
FAIL.each { puts "  FAIL #{_1}" }
exit(FAIL.empty? ? 0 : 1)
