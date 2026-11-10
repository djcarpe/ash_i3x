defmodule AshI3x.Objects do
  @moduledoc false

  # Reads and writes the records behind Objects through Ash, for
  # `AshI3x.Source.Resources`. Everything runs as the request's actor and
  # tenant with `authorize?: true`; an Object the actor cannot read does not
  # exist as far as the API is concerned.
  #
  # A record is passed around as an `{exposure, record}` pair.

  alias AshI3x.Catalog
  alias AshI3x.Resource.Info

  @to_one ["HasParent", "ComponentOf"]

  @doc "The Objects with these elementIds, as a map. Unknown elementIds are absent."
  def fetch(element_ids, ctx) do
    element_ids
    |> Enum.uniq()
    |> Enum.flat_map(&Catalog.locate(ctx.catalog, &1))
    |> Enum.group_by(fn {exposure, _key} -> exposure end, fn {_exposure, key} -> key end)
    |> Enum.reduce(%{}, fn {exposure, keys}, found ->
      attribute = Ash.Resource.Info.attribute(exposure.resource, exposure.identifier)

      case for key <- keys, {:ok, cast} <- [cast(attribute, key)], not is_nil(cast), do: cast do
        [] ->
          found

        keys ->
          exposure
          |> query(ctx)
          |> Ash.Query.do_filter([{exposure.identifier, [in: keys]}])
          |> Ash.read!()
          |> Enum.reduce(found, &Map.put_new(&2, Info.element_id(&1), {exposure, &1}))
      end
    end)
  end

  defp cast(attribute, key) do
    Ash.Type.cast_input(attribute.type, key, attribute.constraints)
  rescue
    _ -> :error
  end

  @doc "Every Object, optionally only those of one type or those without a parent."
  def list(ctx, type, root?) do
    exposures =
      case type do
        nil -> Map.values(ctx.catalog.exposures)
        type -> List.wrap(ctx.catalog.types[type])
      end

    Enum.flat_map(exposures, fn exposure ->
      roots =
        for %{type: type, relationship: relationship} <- exposure.edges,
            root? and type in @to_one,
            do: {relationship.source_attribute, [is_nil: true]}

      exposure
      |> query(ctx)
      |> Ash.Query.do_filter(roots)
      |> Ash.read!()
      |> Enum.map(&{exposure, &1})
    end)
  end

  @doc """
  The Objects related to each of the given ones, as a map of elementId to
  `{relationship type, object}` edges. Declared relationships are followed
  forwards, and everything pointing at an Object is reported back under the
  reverse type, so the graph reads the same from either end.

  `only` is `:all` or the relationship types wanted.
  """
  def edges(objects, ctx, only) do
    objects
    |> Enum.group_by(&elem(&1, 0), &elem(&1, 1))
    |> Enum.flat_map(fn {exposure, records} ->
      outbound(exposure, records, ctx, only) ++ inbound(exposure, records, ctx, only)
    end)
    |> Enum.uniq_by(fn {id, {type, {_exposure, target}}} ->
      {id, type, Info.element_id(target)}
    end)
    |> Enum.group_by(&elem(&1, 0), &elem(&1, 1))
  end

  defp outbound(exposure, records, ctx, only) do
    case Enum.filter(exposure.edges, &wanted?(only, &1.type)) do
      [] ->
        []

      edges ->
        loads =
          for edge <- edges,
              do: {edge.relationship.name, query(ctx.catalog.exposures[edge.destination], ctx)}

        for record <- Ash.load!(records, loads, opts(exposure, ctx)),
            edge <- edges,
            target <- List.wrap(Map.get(record, edge.relationship.name)),
            do:
              {Info.element_id(record),
               {edge.type, {ctx.catalog.exposures[edge.destination], target}}}
    end
  end

  defp inbound(exposure, records, ctx, only) do
    for {source, edge} <- Map.get(ctx.catalog.inbound, exposure.resource, []),
        wanted?(only, edge.reverse),
        {target, record} <- sources(source, edge.relationship, exposure, records, ctx),
        do: {Info.element_id(target), {edge.reverse, {source, record}}}
  end

  # The records of `source` whose relationship reaches one of `targets`,
  # paired with the target reached.
  defp sources(source, relationship, exposure, targets, ctx) do
    if direct?(relationship) do
      by_key = Enum.group_by(targets, &Map.get(&1, relationship.destination_attribute))

      source
      |> query(ctx)
      |> Ash.Query.do_filter([{relationship.source_attribute, [in: Map.keys(by_key)]}])
      |> Ash.read!()
      |> Enum.flat_map(fn record ->
        for target <- Map.get(by_key, Map.get(record, relationship.source_attribute), []),
            do: {target, record}
      end)
    else
      keys = [{exposure.identifier, [in: Enum.map(targets, &Map.get(&1, exposure.identifier))]}]

      source
      |> query(ctx)
      |> Ash.Query.do_filter([{relationship.name, keys}])
      |> Ash.Query.load([
        {relationship.name, exposure |> query(ctx) |> Ash.Query.do_filter(keys)}
      ])
      |> Ash.read!()
      |> Enum.flat_map(fn record ->
        for target <- List.wrap(Map.get(record, relationship.name)), do: {target, record}
      end)
    end
  end

  # Whether the relationship is a plain attribute match, which can be
  # reversed with one filter instead of a join.
  defp direct?(relationship) do
    relationship.type != :many_to_many and is_nil(Map.get(relationship, :filter)) and
      Map.get(relationship, :no_attributes?) != true
  end

  defp wanted?(:all, _type), do: true
  defp wanted?(only, type), do: type in only

  @doc "The historical values of an Object. Without a history module there are none."
  def history({%{history: nil}, _record}, _from, _to, _ctx), do: {:ok, []}

  def history({%{history: {module, opts}}, record}, from, to, ctx) do
    module.read(record, from, to, history_opts(opts, ctx))
  end

  @doc "Whether the Object's resource can have history written."
  def history_writable?(%{history: {module, _opts}}),
    do: Code.ensure_loaded?(module) and function_exported?(module, :write, 3)

  def history_writable?(_exposure), do: false

  @doc "Writes one historical value."
  def write_history({%{history: {module, opts}}, record}, entry, ctx),
    do: module.write(record, entry, history_opts(opts, ctx))

  defp history_opts(opts, ctx), do: Keyword.merge(opts, actor: ctx.actor, tenant: ctx.tenant)

  @doc """
  Replaces an Object's current value by running the resource's update
  action. A structured value replaces every field the action accepts; fields
  the value leaves out are written as nil.
  """
  def write({exposure, record}, value, quality, timestamp, ctx) do
    action = Ash.Resource.Info.action(exposure.resource, exposure.update_action)
    accepted = Enum.map(action.accept, & &1) ++ Enum.map(action.arguments, & &1.name)

    with {:ok, params} <- params(exposure, value, accepted) do
      params =
        [{exposure.quality, quality(exposure, quality)}, {exposure.timestamp, timestamp}]
        |> Enum.filter(fn {field, given} -> field in accepted and not is_nil(given) end)
        |> Map.new()
        |> Map.merge(params)

      record
      |> Ash.Changeset.for_update(action.name, params, opts(exposure, ctx))
      |> Ash.update()
    end
  end

  # The quality in whichever spelling its attribute takes: `"GoodNoData"` for a
  # string, `:good_no_data` for an atom or enum.
  defp quality(%{quality: attribute, resource: resource}, quality)
       when not is_nil(attribute) and not is_nil(quality) do
    %{type: type, constraints: constraints} = Ash.Resource.Info.attribute(resource, attribute)

    Enum.find(
      [quality, Macro.underscore(quality)],
      quality,
      &match?({:ok, _}, Ash.Type.cast_input(type, &1, constraints))
    )
  end

  defp quality(_exposure, quality), do: quality

  defp params(%{scalar?: true, fields: [field]}, value, accepted) do
    if field in accepted,
      do: {:ok, %{field => value}},
      else: {:error, {:invalid, "the value of this Object cannot be written"}}
  end

  defp params(%{fields: fields}, value, accepted) when is_map(value) do
    known = Map.new(fields, &{to_string(&1), &1})

    case Enum.reject(Map.keys(value), &(known[&1] in accepted)) do
      [] ->
        {:ok,
         for(field <- fields, field in accepted, into: %{}, do: {field, value[to_string(field)]})}

      unknown ->
        {:error, {:invalid, "cannot write #{Enum.join(unknown, ", ")}"}}
    end
  end

  defp params(_exposure, _value, _accepted),
    do: {:error, {:invalid, "the value must be an object"}}

  defp query(exposure, ctx) do
    exposure.resource
    |> Ash.Query.for_read(exposure.read_action, %{}, opts(exposure, ctx))
    |> Ash.Query.load(exposure.loads)
  end

  defp opts(exposure, ctx),
    do: [actor: ctx.actor, tenant: ctx.tenant, domain: exposure.domain, authorize?: true]
end
