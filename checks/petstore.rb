# frozen_string_literal: true

# Calling the Petstore client the way an application would. Nothing here runs;
# `rake steep` reads it against examples/petstore/petstore.rbs.

client = Petstore::Client.new(
  base_url: "https://petstore3.swagger.io/api/v3",
  auth: { petstore_auth: "token", api_key: "key" },
  timeout: { open: 2, read: 10 },
  retries: 1
)

# A path parameter is positional, and typed by what the document said it was.
pet = client.get_pet_by_id(42)

# What the document required is not nilable; what it did not, is.
pet.name.upcase
pet.photo_urls.each { |url| url.start_with?("https") }
pet.id&.abs
pet.category&.name&.downcase
pet.tags&.map { |tag| tag.id }

# A required query parameter is a required keyword. An optional one has a
# default, so both calls below are whole.
client.find_pets_by_status(status: "available").map { |found| found.name }
client.find_pets_by_tags(tags: %w[large friendly])
client.update_pet_with_form(42, name: "Rex", status: "pending")
client.update_pet_with_form(42)

# A header parameter is a keyword under the name Ruby will take.
client.delete_pet(42, api_key: "key")

# A model is a value: `new` demands the required fields and `with` returns the
# same model, so a client call takes what a previous one returned.
made = Petstore::Pet.new(name: "Rex", photo_urls: ["https://example.test/rex.jpg"])
client.add_pet(made.with(status: "pending")).name
client.update_pet(pet).id&.abs

# A response the document did not describe as an object keeps its own type.
client.get_inventory.values.sum
client.login_user(username: "u", password: "p").length

# A binary body is a String, optional because the document did not require one.
client.upload_file(42, "\x89PNG", additional_metadata: "scan").code&.abs
client.upload_file(42)

# An operation with no response schema returns `untyped` rather than nothing,
# because the document did not say what comes back.
client.logout_user
