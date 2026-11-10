spark_locals_without_parens = [
  component_of: 1,
  description: 1,
  display_name: 1,
  history: 1,
  identifier: 1,
  namespace: 1,
  parent: 1,
  prefix: 1,
  quality: 1,
  read_action: 1,
  relationship: 2,
  relationship: 3,
  reverse: 1,
  source_type_id: 1,
  timestamp: 1,
  type: 1,
  type_display_name: 1,
  update_action: 1,
  value: 1,
  version: 1
]

[
  import_deps: [:ash, :spark, :plug],
  inputs: ["{mix,.formatter}.exs", "{config,lib,test}/**/*.{ex,exs}"],
  locals_without_parens: spark_locals_without_parens,
  export: [locals_without_parens: spark_locals_without_parens]
]
