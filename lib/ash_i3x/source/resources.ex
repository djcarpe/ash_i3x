defmodule AshI3x.Source.Resources do
  @moduledoc false

  # The source behind `AshI3x.Plug`'s `:domains`: every resource that uses
  # `AshI3x.Resource` is an Object Type and each of its records an Object.
  # An Object's `data` is the `{exposure, record}` pair `AshI3x.Objects` works on.

  @behaviour AshI3x.Source

  alias AshI3x.Catalog
  alias AshI3x.Object
  alias AshI3x.Objects
  alias AshI3x.Resource.Info
  alias AshI3x.Value

  @impl true
  def namespaces(_ctx, opts), do: catalog(opts).namespaces

  @impl true
  def object_types(_ctx, opts) do
    for {_type, exposure} <- catalog(opts).types do
      type = %{
        elementId: exposure.type,
        displayName: exposure.type_display_name,
        namespaceUri: exposure.namespace,
        sourceTypeId: exposure.source_type_id,
        schema: exposure.schema
      }

      if exposure.version, do: Map.put(type, :version, exposure.version), else: type
    end
  end

  @impl true
  def relationship_types(_ctx, opts), do: catalog(opts).relationship_types

  @impl true
  def capabilities(_ctx, opts) do
    exposures = Map.values(catalog(opts).exposures)

    %{
      history: Enum.any?(exposures, &(not is_nil(&1.history))),
      write: Enum.any?(exposures, &(not is_nil(&1.update_action))),
      write_history: Enum.any?(exposures, &Objects.history_writable?/1)
    }
  end

  @impl true
  def list(%{type: type, root?: root?}, ctx, opts),
    do: ctx |> with_catalog(opts) |> Objects.list(type, root?) |> Enum.map(&object/1)

  @impl true
  def fetch(element_ids, ctx, opts),
    do: element_ids |> Objects.fetch(with_catalog(ctx, opts)) |> Enum.map(&object(elem(&1, 1)))

  @impl true
  def related(objects, only, ctx, opts) do
    objects
    |> Enum.map(& &1.data)
    |> Objects.edges(with_catalog(ctx, opts), only)
    |> Map.new(fn {id, edges} ->
      {id, for({type, target} <- edges, do: {type, object(target)})}
    end)
  end

  @impl true
  def values(objects, _ctx, _opts) do
    Map.new(objects, fn %{element_id: id, data: {exposure, record}} ->
      {id, Value.vqt(exposure, record)}
    end)
  end

  @impl true
  def write(%{data: pair}, value, quality, timestamp, ctx, opts),
    do: Objects.write(pair, value, quality, timestamp, with_catalog(ctx, opts))

  @impl true
  def history(%{data: pair}, from, to, ctx, _opts), do: Objects.history(pair, from, to, ctx)

  @impl true
  def write_history(%{data: pair}, entry, ctx, _opts), do: Objects.write_history(pair, entry, ctx)

  # A change can be handed to a subscriber as notified only when there is
  # nothing to authorize and nothing to load.
  @impl true
  def changed(_element_id, {:record, resource, record}, _ctx, opts) do
    case catalog(opts).exposures[resource] do
      nil -> :skip
      %{reread?: true} -> :reread
      exposure -> {:ok, Value.vqt(exposure, record)}
    end
  end

  def changed(_element_id, _payload, _ctx, _opts), do: :reread

  @doc "What tells a record's changes apart from another tenant's: a tenant only matters when the resource is multitenant."
  def tenant(resource, tenant) do
    case Ash.Resource.Info.multitenancy_strategy(resource) do
      nil -> nil
      _ -> tenant
    end
  end

  defp object({exposure, %resource{} = record} = pair) do
    %Object{
      element_id: Info.element_id(record),
      type: exposure.type,
      namespace: exposure.namespace,
      source_type_id: exposure.source_type_id,
      display_name: field(record, exposure.display_name),
      description: field(record, exposure.description),
      writable?: not is_nil(exposure.update_action),
      history_writable?: Objects.history_writable?(exposure),
      tenant: if(Ash.Resource.Info.multitenancy_strategy(resource), do: :request),
      data: pair
    }
  end

  defp field(_record, nil), do: nil

  defp field(record, attribute) do
    case Map.get(record, attribute) do
      nil -> nil
      value -> to_string(value)
    end
  end

  defp catalog(opts), do: Catalog.get(opts.domains, opts)
  defp with_catalog(ctx, opts), do: Map.put(ctx, :catalog, catalog(opts))
end
