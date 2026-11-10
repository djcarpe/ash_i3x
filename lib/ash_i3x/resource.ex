defmodule AshI3x.Resource do
  @relationship %Spark.Dsl.Entity{
    name: :relationship,
    describe: """
    Exposes an Ash relationship as an i3X graph relationship. Hierarchy and
    composition have their own options (`parent` and `component_of`); use this
    for everything else.
    """,
    examples: [
      ~S|relationship :tank, "SuppliesTo", reverse: "SuppliedBy"|
    ],
    target: AshI3x.Resource.Relationship,
    args: [:relationship, :type],
    identifier: :relationship,
    schema: AshI3x.Resource.Relationship.schema()
  }

  @i3x %Spark.Dsl.Section{
    name: :i3x,
    describe: """
    Exposes the resource over i3X. The resource becomes an Object Type and
    each of its records an Object.
    """,
    examples: [
      """
      i3x do
        namespace "https://example.com/ns/equipment"
        display_name :name
        parent :line
        value [:flow_rate, :outlet_temp]
        update_action :update
        relationship :tank, "SuppliesTo", reverse: "SuppliedBy"
      end
      """
    ],
    entities: [@relationship],
    schema: [
      type: [
        type: :string,
        doc:
          "The elementId of the Object Type. Defaults to the last segment of the module name followed by `Type`."
      ],
      type_display_name: [
        type: :string,
        doc:
          "The displayName of the Object Type. Defaults to the last segment of the module name."
      ],
      namespace: [
        type: :string,
        doc:
          "The URI of the Namespace the Object Type belongs to. Defaults to the `:namespace` option of `AshI3x.Plug`."
      ],
      version: [
        type: :string,
        doc: "The semantic version of the Object Type, e.g. `\"1.0.0\"`."
      ],
      source_type_id: [
        type: :string,
        doc: "The identifier of the type within its source namespace. Defaults to `type`."
      ],
      prefix: [
        type: {:or, [:string, {:literal, false}]},
        doc: """
        Each Object's elementId is `"<prefix>:<identifier>"`, which is how an
        elementId is routed back to its resource. Defaults to the underscored
        last segment of the module name. Set to `false` when the identifier is
        already unique across every exposed resource; lookups then try each
        unprefixed resource in turn.
        """
      ],
      identifier: [
        type: :atom,
        doc: "The unique attribute elementIds are built from. Defaults to the primary key."
      ],
      display_name: [
        type: :atom,
        doc: "The attribute holding each Object's displayName. Defaults to the elementId."
      ],
      description: [
        type: :atom,
        doc: "The attribute holding each Object's description."
      ],
      value: [
        type: {:or, [:atom, {:list, :atom}]},
        doc: """
        What an Object's value is made of. A list of attributes, calculations
        or aggregates makes a structured value; a single name makes a scalar
        (leaf) value. Defaults to the public attributes that are not otherwise
        used by this section or as a relationship's foreign key.
        """
      ],
      quality: [
        type: :atom,
        doc: """
        The attribute holding the quality of the value: `Good`, `GoodNoData`,
        `Bad` or `Uncertain`, as a string or a snake_case atom. Without it,
        quality is `Good` when there is a value and `GoodNoData` otherwise.
        """
      ],
      timestamp: [
        type: :atom,
        doc:
          "The attribute holding when the value was recorded. Defaults to `:updated_at` when the resource has it, and otherwise to the time of the request."
      ],
      parent: [
        type: :atom,
        doc:
          "The `belongs_to` relationship to the Object that organizes this one (`HasParent`/`HasChildren`)."
      ],
      component_of: [
        type: :atom,
        doc:
          "The `belongs_to` relationship to the Object this one is a part of (`ComponentOf`/`HasComponent`)."
      ],
      read_action: [
        type: :atom,
        doc: "The read action used for every lookup. Defaults to the primary read action."
      ],
      update_action: [
        type: :atom,
        doc:
          "The update action `PUT /objects/value` runs. Without it the resource's Objects are read-only."
      ],
      history: [
        type: {:or, [:module, {:tuple, [:module, :keyword_list]}]},
        doc: "An `AshI3x.History` module, or `{module, opts}`, serving `/objects/history`."
      ]
    ]
  }

  @moduledoc """
  The resource extension. Add it to a resource and describe the mapping in an
  `i3x` section; serve the result with `AshI3x.Plug`.

      defmodule MyApp.Plant.Pump do
        use Ash.Resource,
          domain: MyApp.Plant,
          data_layer: AshPostgres.DataLayer,
          extensions: [AshI3x.Resource]

        i3x do
          namespace "https://example.com/ns/equipment"
          display_name :name
          parent :line
          value [:flow_rate, :outlet_temp]
          update_action :update
        end
      end

  The extension also adds `AshI3x.Notifier` to the resource, which is what
  feeds subscriptions.
  """

  use Spark.Dsl.Extension,
    sections: [@i3x],
    transformers: [AshI3x.Resource.AddNotifier],
    verifiers: [AshI3x.Resource.Verify]
end
