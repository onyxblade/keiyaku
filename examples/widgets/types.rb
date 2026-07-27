# frozen_string_literal: true
# Generated from the OpenAPI document. Edits will be overwritten.

require "openapi/runtime"

module Widgets
  Widget = OpenAPI.model(
    id: Integer,
    created_at: Time,
    labels: { String => String },
    retired: :bool,
    required: %i[id created_at],
    from: { created_at: "created_at" }
  )
  Problem = OpenAPI.model(
    detail: String,
    trace_id: String,
    required: %i[detail],
    from: { trace_id: "trace_id" }
  )
end
