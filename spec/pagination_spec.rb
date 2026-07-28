# frozen_string_literal: true

# Pagination is declared in the document with `x-keiyaku-paginate`, because
# OpenAPI has no way to describe it and a parameter named `page` is not
# evidence of anything. Each strategy gets an `#{operation}_each`.
RSpec.describe "pagination" do
  it "returns an enumerator that makes only the requests it is asked for" do
    first = widgets.list_events_each(7).lazy.first(1)

    expect(first.map(&:id)).to eq [1]
    expect(sent.query).to include("offset" => "0")
    expect(TestServer.requests).to be_empty
  end

  it "takes a block as well as returning an enumerator" do
    seen = []
    widgets.widget_feed_each { seen << _1.id }
    expect(seen).to eq [1, 2]
  end

  describe "by offset" do
    let!(:ids) { widgets.list_events_each(7).map(&:id) }
    let(:requests) { sent_all(3) }

    it "walks until a page comes back short" do
      expect(ids).to eq [1, 2, 3, 4, 5]
    end

    it "advances the offset by the page size" do
      expect(requests.map { _1.query["offset"] }).to eq %w[0 2 4]
    end

    it "sends the page size the document declared" do
      expect(requests.map { _1.query["limit"] }).to all(eq "2")
    end
  end

  describe "by cursor" do
    let!(:ids) { widgets.search_widgets_each(q: "kaya").map(&:id) }
    let(:requests) { sent_all(3) }

    it "digs the items out of the envelope" do
      expect(ids).to eq [1, 2, 3]
    end

    it "sends no cursor on the first request" do
      expect(requests.first.query).not_to include("cursor")
    end

    it "then sends back the cursor it was given" do
      expect(requests.drop(1).map { _1.query["cursor"] }).to eq %w[1 2]
    end

    it "stops when a page arrives without a next cursor" do
      requests # raises if fewer than three were made; an empty queue proves there was no fourth
      expect(TestServer.requests).to be_empty
    end
  end

  describe "by Link header" do
    # The one URL in a call this client does not build, which is why the two
    # examples below answer from a script rather than from the test server:
    # what a `next` can say is the point, and a server that says it honestly
    # cannot say the rest.
    def scripted(*pages)
      Class.new do
        define_method(:initialize) { @pages = pages }
        def seen = @seen ||= []

        def call(_verb, uri, headers, _body)
          seen << [uri.to_s, headers]
          @pages.shift or raise "the client asked for a page after the last one: #{uri}"
        end
      end.new
    end

    def page(items, link: nil)
      headers = { "content-type" => "application/json" }
      headers["link"] = %(<#{link}>; rel="next") if link
      [200, headers, JSON.generate(items.map { TestServer::WIDGET.(_1) })]
    end

    it "follows rel=next until there is none" do
      expect(widgets.widget_feed_each.map(&:id)).to eq [1, 2]
    end

    it "follows the URL the server gave rather than building one" do
      widgets.widget_feed_each.to_a
      expect(sent_all(2).map(&:query)).to eq [{}, { "page" => "2" }]
    end

    # RFC 8288's target may be relative, and it is relative to the URI of the
    # request whose header carried it.
    it "resolves a relative target against the request that carried it" do
      adapter = scripted(page([1], link: "?page=2"), page([2]))

      expect(widgets(adapter:).widget_feed_each.map(&:id)).to eq [1, 2]
      expect(adapter.seen.map(&:first))
        .to eq [TestServer.url("/v1/widgets/feed"), TestServer.url("/v1/widgets/feed?page=2")]
    end

    # The credentials belong to the client and the URL belongs to the server,
    # so a `next` somewhere else is an answer that walks the Authorization
    # header off to a host the document never named.
    it "refuses a target on another origin rather than sending the credentials there" do
      adapter = scripted(page([1], link: "https://other-origin.test/v1/widgets/feed?page=2"))

      expect { widgets(adapter:).widget_feed_each.to_a }
        .to raise_error(Keiyaku::Error, %r{https://other-origin.test.*this client is http://127.0.0.1})
      expect(adapter.seen.map(&:first)).to eq [TestServer.url("/v1/widgets/feed")]
      expect(adapter.seen.first.last).to include("Authorization" => "Bearer t0ken")
    end
  end

  it "still exposes the unpaginated operation, envelope and all" do
    expect(widgets.search_widgets(q: "kaya")).to be_a(Widgets::SearchWidgetsResult)
      .and have_attributes(next_cursor: "1")
  end
end
