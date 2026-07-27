# frozen_string_literal: true
# Generated from the OpenAPI document. Edits will be overwritten.

require_relative "types"

module Petstore
  class Client < Keiyaku::Client
    server "https://petstore3.swagger.io/api/v3"
    security({ header: "api_key" })

    put    :update_pet, "/pet", body: Pet, into: Pet
    post   :add_pet, "/pet", body: Pet, into: Pet
    get    :find_pets_by_status, "/pet/findByStatus", query: %i[status!], into: [Pet]
    get    :find_pets_by_tags, "/pet/findByTags", query: %i[tags!], into: [Pet]
    get    :get_pet_by_id, "/pet/{petId}", into: Pet
    post   :update_pet_with_form, "/pet/{petId}", query: %i[name status], into: Pet
    delete :delete_pet, "/pet/{petId}", header: { "api_key" => :api_key }
    post   :upload_file, "/pet/{petId}/uploadImage", query: %i[additionalMetadata], body: :binary, content_type: "application/octet-stream", into: ApiResponse
    get    :get_inventory, "/store/inventory", into: { String => Integer }
    post   :place_order, "/store/order", body: Order, into: Order
    get    :get_order_by_id, "/store/order/{orderId}", into: Order
    delete :delete_order, "/store/order/{orderId}"
    post   :create_user, "/user", body: User, into: User
    post   :create_users_with_list_input, "/user/createWithList", body: [User], into: User
    get    :login_user, "/user/login", query: %i[username password], into: String
    get    :logout_user, "/user/logout"
    get    :get_user_by_name, "/user/{username}", into: User
    put    :update_user, "/user/{username}", body: User
    delete :delete_user, "/user/{username}"
  end
end
