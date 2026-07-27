# frozen_string_literal: true
# Generated from the OpenAPI document. Edits will be overwritten.

require "openapi/runtime"

module Petstore
  Order = OpenAPI.model(
    id: Integer,
    pet_id: Integer,
    quantity: Integer,
    ship_date: Time,
    status: String,
    complete: :bool
  )
  Category = OpenAPI.model(id: Integer, name: String)
  User = OpenAPI.model(
    id: Integer,
    username: String,
    first_name: String,
    last_name: String,
    email: String,
    password: String,
    phone: String,
    user_status: Integer
  )
  Tag = OpenAPI.model(id: Integer, name: String)
  Pet = OpenAPI.model(
    id: Integer,
    name: String,
    category: Category,
    photo_urls: [String],
    tags: [Tag],
    status: String,
    required: %i[name photo_urls]
  )
  ApiResponse = OpenAPI.model(code: Integer, type: String, message: String)
end
