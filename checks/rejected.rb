# frozen_string_literal: true

# Calls the generated RBS has to refuse. A file of correct usage cannot see the
# difference between a signature that is right and one that has gone `untyped`,
# because both accept it — so each line here is wrong on purpose, and the
# `steep:ignore` on it names the complaint it has to draw. Steep reports an
# ignore that turned out to be unnecessary, so a signature that quietly stops
# constraining what it says it constrains fails the run from this direction.

petstore = Petstore::Client.new(base_url: "https://petstore3.swagger.io/api/v3")
widgets = Widgets::Client.new(base_url: "https://widgets.test", auth: "token")

# A path parameter is the type the document gave it, not whatever reads like
# one at a glance.
petstore.get_pet_by_id("42") # steep:ignore ArgumentTypeMismatch

# An operation takes the parameters it has, and no more.
petstore.get_pet_by_id(42, "extra") # steep:ignore UnexpectedPositionalArgument

# A required query parameter is required.
petstore.find_pets_by_status # steep:ignore InsufficientKeywordArguments

# An optional one goes by the name the document gave it, and a near miss is a
# near miss rather than a parameter that silently does nothing.
petstore.update_pet_with_form(42, nome: "Rex") # steep:ignore UnexpectedKeywordArgument

# What the document did not require comes back nilable, and the nil has to be
# dealt with before the value can be used.
petstore.get_pet_by_id(42).id.abs # steep:ignore NoMethod

# A model demands the fields the document required.
Petstore::Pet.new(id: 1) # steep:ignore InsufficientKeywordArguments

# A model is a frozen value, so there is nothing to assign to.
petstore.get_pet_by_id(42).name = "Rex" # steep:ignore NoMethod

# Two documents' models are two types, however alike they look.
petstore.add_pet(Widgets::Widget.new(id: 1, created_at: Time.now)) # steep:ignore ArgumentTypeMismatch

# A response that is not a model is still typed all the way down.
petstore.get_inventory.each_value { |count| count.upcase } # steep:ignore NoMethod

# Two success statuses are two types, and neither is available until the caller
# has said which one it is holding.
widgets.import_widgets("id,name\n").job_id # steep:ignore NoMethod

# A discriminated union is the same: the variant's own fields arrive only once
# the caller has narrowed to that variant.
widgets.list_events(1).each { |event| event.widget } # steep:ignore NoMethod

# The one operation the generator refused is in the signature, with a reason,
# returning a type that has no methods — so the refusal reaches the caller as a
# type error at the point of use rather than as a client that quietly lacks it.
widgets.list_widgets.length # steep:ignore NoMethod
