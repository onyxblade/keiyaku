# frozen_string_literal: true

# Calling the Widgets client, which is where the awkward constructs live: two
# success types on one operation, a parameter Ruby will not read as a name, a
# discriminated union, an upload, and a `deepObject` filter.

client = Widgets::Client.new(base_url: "https://widgets.test", auth: "token")

widget = client.get_widget(1)
widget.id.abs
widget.created_at.utc
widget.labels&.fetch("team", nil)
widget.retired

# `until` is a keyword to Ruby and a parameter name to the document, and the
# document wins.
imported = client.import_widgets("id,name\n1,Rex\n", until: Time.now)

# Two success statuses that are two types are a union, so a caller has to say
# which one it is holding before it can use either.
if imported.is_a?(Array)
  imported.map { |each| each.id }
else
  imported.job_id.length
end

# A `oneOf` with a discriminator is a union of the variants, narrowed the
# ordinary way.
client.list_events(1, limit: 10, offset: 0).each do |event|
  case event
  when Widgets::WidgetCreated then event.widget.created_at.iso8601
  when Widgets::WidgetRetired then event.reason&.upcase
  end
end

# A multipart body is a model like any other; the file field takes an IO or the
# wrapper that carries a filename and a content type.
client.upload_photo(
  1,
  Widgets::UploadPhotoBody.new(
    file: Keiyaku::Upload.new(File.open("/dev/null"), filename: "photo.png", content_type: "image/png"),
    caption: "a widget",
    tags: %w[new]
  )
).id.abs

client.upload_photo(1, Widgets::UploadPhotoBody.new(file: File.open("/dev/null")))

# A `deepObject` query parameter on an object is a model, not a loose Hash.
found = client.search_widgets(q: "rex", filter: Widgets::SearchWidgetsFilter.new(status: "active", since: Time.now))
found.items&.first&.id&.abs
found.next_cursor&.length
client.search_widgets(q: "rex")

# A body the document never required has a default; array and object header
# parameters keep their shape.
client.add_note(1, locale: "en").text
client.add_note(1, Widgets::Note.new(text: "hi", locale: "en"), locale: "en").locale&.length
client.replace_labels(1, { "team" => "core" }, x_tags: %w[a b], x_context: { "trace" => "1" }).fetch("team")
client.replace_labels(1, {}).each_pair { |name, value| name.length + value.length }

client.create_widget(Widgets::Widget.new(id: 1, created_at: Time.now)).id.abs
client.create_widget
