# frozen_string_literal: true
# Generated from the OpenAPI document. Edits will be overwritten.

require "keiyaku/runtime"

module Petstore
  Order = Keiyaku.model(
    id: Integer,
    pet_id: Integer,
    quantity: Integer,
    ship_date: Time,
    status: String,
    complete: :bool
  )
  Category = Keiyaku.model(id: Integer, name: String)
  User = Keiyaku.model(
    id: Integer,
    username: String,
    first_name: String,
    last_name: String,
    email: String,
    password: String,
    phone: String,
    user_status: Integer
  )
  Tag = Keiyaku.model(id: Integer, name: String)
  Pet = Keiyaku.model(
    id: Integer,
    name: String,
    category: Category,
    photo_urls: [String],
    tags: [Tag],
    status: String,
    required: %i[name photo_urls]
  )
  ApiResponse = Keiyaku.model(code: Integer, type: String, message: String)
end
