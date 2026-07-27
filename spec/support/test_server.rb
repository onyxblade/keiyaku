# frozen_string_literal: true

require "json"
require "socket"
require "uri"

# A real HTTP server on a real socket, so the specs exercise the whole path —
# signature, serialization, transport, decoding, error mapping — rather than a
# stubbed adapter that would agree with whatever the runtime happened to do.
#
# Every request it answers is also recorded, so an example can assert on what
# went out as well as on what came back.
module TestServer
  Request = Data.define(:verb, :target, :headers, :body) do
    def path = target.split("?").first
    def query = URI.decode_www_form(target.split("?", 2)[1].to_s).to_h
    def content_type = headers["content-type"]
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

  class << self
    def requests = @requests ||= Queue.new

    def url(path = "") = "http://127.0.0.1:#{@port}#{path}"

    def start
      listener = TCPServer.new("127.0.0.1", 0)
      @port = listener.addr[1]
      @thread = Thread.new { loop { serve(listener.accept) } }
      self
    end

    # The next request the server received. Blocks, because it is recorded on
    # the server's thread, but fails instead of hanging if none arrives.
    def take
      requests.pop(timeout: 5) or raise "expected the client to make a request, and it made none"
    end

    private

    def serve(socket)
      request = read(socket)
      requests << request
      status, payload, extra = route(request)
      write(socket, status, payload, extra)
    rescue StandardError => e
      warn "test server: #{e.class}: #{e.message}"
    ensure
      socket.close
    end

    def read(socket)
      verb, target, = socket.gets.split
      headers = {}
      while (line = socket.gets) && line != "\r\n"
        key, value = line.split(": ", 2)
        headers[key.downcase] = value.to_s.strip
      end
      body = headers["content-length"] ? socket.read(headers["content-length"].to_i) : nil
      Request.new(verb:, target:, headers:, body:)
    end

    def write(socket, status, payload, extra)
      encoded = payload.nil? ? "" : JSON.generate(payload)
      socket.print "HTTP/1.1 #{status}\r\nContent-Type: application/json\r\n" \
                   "#{extra.to_h.map { |k, v| "#{k}: #{v}\r\n" }.join}" \
                   "Content-Length: #{encoded.bytesize}\r\nConnection: close\r\n\r\n#{encoded}"
    end

    # Returns [status, payload, extra headers].
    def route(request)
      query = request.query

      case [request.verb, request.path]
      in ["GET", "/api/v3/pet/findByStatus"] then [200, [PET]]
      in ["GET", "/api/v3/pet/findByTags"] then [200, []]
      in ["GET", "/api/v3/pet/5"] then [200, PET]
      in ["GET", "/api/v3/pet/999"] then [404, { "code" => 404, "type" => "error", "message" => "Pet not found" }]
      in ["GET", "/api/v3/store/inventory"] then [200, { "available" => 12, "sold" => 3 }]
      in ["GET", "/api/v3/user/login"] then [200, "session-token"]
      in ["POST", "/api/v3/pet"] then [200, JSON.parse(request.body)]
      in ["DELETE", "/api/v3/pet/5"] then [200, nil]
      in ["POST", "/api/v3/pet/5/uploadImage"] then [200, { "code" => 200, "type" => "ok", "message" => "stored" }]

      in ["GET", "/v1/widgets/1"] then
        [200, { "id" => 1, "created_at" => "2026-07-26T10:00:00Z",
                "labels" => { "env" => "prod" }, "retired" => false }]
      in ["GET", "/v1/widgets/2"] then [500, { "detail" => "boom", "trace_id" => "t-1" }]
      in ["POST", "/v1/widgets"] then [422, { "detail" => "that id is taken", "source" => "id" }]
      in ["POST", "/v1/widgets/1/photo"] then [200, WIDGET.(1)]
      in ["GET", "/v1/widgets/1/events"] then
        [200, [{ "kind" => "created",
                 "widget" => { "id" => 1, "created_at" => "2026-07-26T10:00:00Z" } },
               { "kind" => "retired", "id" => 1, "reason" => "end of life" }]]
      in ["GET", "/v1/widgets/3/events"] then [200, [{ "kind" => "exploded" }]]

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
          [200, [WIDGET.(1)], { "Link" => %(<#{url("/v1/widgets/feed?page=2")}>; rel="next") }]
        end

      else [500, { "message" => "unexpected #{request.verb} #{request.target}" }]
      end
    end
  end
end
