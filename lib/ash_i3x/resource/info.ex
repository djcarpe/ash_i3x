defmodule AshI3x.Resource.Info do
  @moduledoc "Introspection for the `AshI3x.Resource` extension, with defaults resolved."

  alias Spark.Dsl.Extension

  @reserved ~w(description display_name identifier quality timestamp)a

  @doc "Whether a resource uses `AshI3x.Resource`."
  def exposed?(resource), do: AshI3x.Resource in Spark.extensions(resource)

  @doc "The elementId of the resource's Object Type."
  def type(resource), do: opt(resource, :type) || short_name(resource) <> "Type"

  def type_display_name(resource), do: opt(resource, :type_display_name) || short_name(resource)
  def namespace(resource), do: opt(resource, :namespace)
  def version(resource), do: opt(resource, :version)
  def source_type_id(resource), do: opt(resource, :source_type_id) || type(resource)

  @doc "The elementId prefix, or nil when the resource is unprefixed."
  def prefix(resource) do
    case opt(resource, :prefix) do
      nil -> resource |> short_name() |> Macro.underscore()
      false -> nil
      prefix -> prefix
    end
  end

  @doc "The attribute elementIds are built from, or nil when the primary key is composite."
  def identifier(resource) do
    case opt(resource, :identifier) || Ash.Resource.Info.primary_key(resource) do
      [key] -> key
      key when is_atom(key) -> key
      _ -> nil
    end
  end

  def display_name(resource), do: opt(resource, :display_name)
  def description(resource), do: opt(resource, :description)
  def quality(resource), do: opt(resource, :quality)

  def timestamp(resource) do
    opt(resource, :timestamp) ||
      if Ash.Resource.Info.attribute(resource, :updated_at), do: :updated_at
  end

  def parent(resource), do: opt(resource, :parent)
  def component_of(resource), do: opt(resource, :component_of)
  def update_action(resource), do: opt(resource, :update_action)

  def read_action(resource) do
    opt(resource, :read_action) ||
      case Ash.Resource.Info.primary_action(resource, :read) do
        nil -> nil
        action -> action.name
      end
  end

  @doc "The history module and its options, or nil."
  def history(resource) do
    case opt(resource, :history) do
      nil -> nil
      {module, opts} -> {module, opts}
      module -> {module, []}
    end
  end

  @doc "The graph relationships a resource exposes."
  @spec relationships(Spark.Dsl.t() | Ash.Resource.t()) :: [AshI3x.Resource.Relationship.t()]
  def relationships(resource), do: Extension.get_entities(resource, [:i3x])

  @doc "The fields making up the value, and whether the value is a scalar."
  @spec value(Spark.Dsl.t() | Ash.Resource.t()) :: {[atom], scalar? :: boolean}
  def value(resource) do
    case opt(resource, :value) do
      nil -> {default_value(resource), false}
      fields when is_list(fields) -> {fields, false}
      field -> {[field], true}
    end
  end

  @doc "The elementId of a record of an exposed resource."
  def element_id(%resource{} = record) do
    key = record |> Map.get(identifier(resource)) |> to_string()

    case prefix(resource) do
      nil -> key
      prefix -> prefix <> ":" <> key
    end
  end

  defp default_value(resource) do
    used =
      Enum.map(@reserved, &apply(__MODULE__, &1, [resource])) ++
        Ash.Resource.Info.primary_key(resource) ++
        for(
          %{type: :belongs_to} = rel <- Ash.Resource.Info.relationships(resource),
          do: rel.source_attribute
        )

    for attribute <- Ash.Resource.Info.public_attributes(resource),
        attribute.name not in used,
        do: attribute.name
  end

  defp opt(resource, name), do: Extension.get_opt(resource, [:i3x], name, nil)

  defp short_name(resource) when is_atom(resource),
    do: resource |> Module.split() |> List.last()

  defp short_name(dsl), do: dsl |> Extension.get_persisted(:module) |> short_name()
end
