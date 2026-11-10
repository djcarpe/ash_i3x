defmodule AshI3x.Sources do
  @moduledoc false

  # Everything the plug serves, put together from its sources: the resources
  # of the domains (`AshI3x.Source.Resources`) and any `AshI3x.Source` given.
  # `ctx.sources` is a list of `{module, opts}`.

  alias AshI3x.Object
  alias AshI3x.Value

  @i3x_namespace "https://cesmii.org/i3x"
  @hierarchy [{"HasParent", "HasChildren"}, {"ComponentOf", "HasComponent"}]
  @to_one ["HasParent", "ComponentOf"]

  @doc "The sources a plug with these options serves."
  def from_opts(opts) do
    resources =
      case opts[:domains] do
        nil ->
          []

        domains ->
          [
            {AshI3x.Source.Resources,
             %{domains: domains, namespace: opts[:namespace], namespaces: opts[:namespaces]}}
          ]
      end

    resources ++
      Enum.map(opts[:sources] || [], fn
        {module, source_opts} when is_atom(module) -> {module, source_opts}
        module when is_atom(module) -> {module, []}
      end)
  end

  def namespaces(ctx) do
    names = Map.new(ctx[:namespaces] || %{})

    [%{uri: @i3x_namespace, displayName: "i3X"} | each(ctx, :namespaces, [])]
    |> Enum.uniq_by(& &1.uri)
    |> Enum.map(&%{&1 | displayName: Map.get(names, &1.uri, &1.displayName)})
  end

  def object_types(ctx), do: ctx |> each(:object_types, []) |> Enum.uniq_by(& &1.elementId)

  def relationship_types(ctx) do
    builtin =
      for {type, reverse} <- @hierarchy,
          {id, reverse_of} <- [{type, reverse}, {reverse, type}] do
        %{
          elementId: id,
          displayName: id,
          namespaceUri: @i3x_namespace,
          relationshipId: id,
          reverseOf: reverse_of
        }
      end

    Enum.uniq_by(builtin ++ each(ctx, :relationship_types, []), & &1.elementId)
  end

  @doc "Whether any source can do this: `:history`, `:write` or `:write_history`."
  def can?(ctx, what) do
    Enum.any?(ctx.sources, fn {module, opts} = source ->
      if exports?(source, :capabilities, 2),
        do: module.capabilities(ctx, opts)[what] == true,
        else: false
    end)
  end

  defp each(ctx, callback, args) do
    Enum.flat_map(ctx.sources, fn {module, opts} = source ->
      if exports?(source, callback, length(args) + 2),
        do: apply(module, callback, args ++ [ctx, opts]),
        else: []
    end)
  end

  defp exports?({module, _opts}, callback, arity),
    do: Code.ensure_loaded?(module) and function_exported?(module, callback, arity)

  @doc "Every Object, optionally only those of one type or those without a parent."
  def list(ctx, type, root?) do
    Enum.flat_map(ctx.sources, fn {module, opts} = source ->
      %{type: type, root?: root?} |> module.list(ctx, opts) |> Enum.map(&own(&1, source, ctx))
    end)
  end

  @doc "The Objects with these elementIds, as a map. Unknown elementIds are absent."
  def fetch(element_ids, ctx) do
    Enum.reduce(ctx.sources, {Enum.uniq(element_ids), %{}}, fn
      _source, {[], found} ->
        {[], found}

      {module, opts} = source, {wanted, found} ->
        found =
          wanted
          |> module.fetch(ctx, opts)
          |> Enum.reduce(found, &Map.put_new(&2, &1.element_id, own(&1, source, ctx)))

        {Enum.reject(wanted, &is_map_key(found, &1)), found}
    end)
    |> elem(1)
  end

  defp own(%Object{} = object, source, ctx) do
    %{
      object
      | source: source,
        tenant: if(object.tenant == :request, do: ctx.tenant, else: object.tenant),
        display_name: object.display_name || object.element_id,
        source_type_id: object.source_type_id || object.type
    }
  end

  @doc """
  The Objects related to each of the given ones, as a map of elementId to
  `{relationship type, object}` edges. `only` is `:all` or the types wanted.
  """
  def edges(objects, ctx, only) do
    objects
    |> Enum.group_by(& &1.source)
    |> Enum.reduce(%{}, fn {{module, opts} = source, objects}, edges ->
      if exports?(source, :related, 4) do
        objects
        |> module.related(only, ctx, opts)
        |> Map.new(fn {id, related} ->
          {id,
           related
           |> Enum.map(fn {type, target} -> {type, own(target, source, ctx)} end)
           |> Enum.uniq_by(fn {type, target} -> {type, target.element_id} end)}
        end)
        |> Map.merge(edges)
      else
        edges
      end
    end)
  end

  @doc "Objects as the API describes them, in the order given."
  def describe(objects, ctx, metadata?) do
    edges = edges(objects, ctx, if(metadata?, do: :all, else: ["HasComponent" | @to_one]))

    for object <- objects do
      edges = Map.get(edges, object.element_id, [])

      described = %{
        elementId: object.element_id,
        displayName: object.display_name,
        typeElementId: object.type,
        parentId: target(edges, "HasParent") || target(edges, "ComponentOf"),
        isComposition: Enum.any?(edges, &match?({"HasComponent", _}, &1)),
        isExtended: false
      }

      if metadata?,
        do: Map.put(described, :metadata, metadata(object, edges)),
        else: described
    end
  end

  defp target(edges, type) do
    Enum.find_value(edges, fn {edge_type, target} -> edge_type == type && target.element_id end)
  end

  defp metadata(object, edges) do
    relationships =
      edges
      |> Enum.group_by(&elem(&1, 0), fn {_type, target} -> target.element_id end)
      |> Map.new(fn
        {type, [id | _]} when type in @to_one -> {type, id}
        {type, ids} -> {type, ids}
      end)

    metadata = %{
      typeNamespaceUri: object.namespace,
      sourceTypeId: object.source_type_id,
      relationships: relationships
    }

    case object.description do
      nil -> metadata
      description -> Map.put(metadata, :description, to_string(description))
    end
  end

  @doc """
  The current value of each Object, as a map of elementId to result, and
  whether the server's depth limit cut any composition short.

  `max_depth` counts levels from the Object itself: 1 is the Object alone, 0
  is no limit but the server's.
  """
  def values(objects, max_depth, ctx) do
    {components, partial?} =
      descend(Enum.map(objects, &{&1.element_id, &1}), 1, max_depth, ctx, %{})

    below = for {_root, found} when is_list(found) <- components, object <- found, do: object
    vqts = vqts(Enum.uniq_by(objects ++ below, & &1.element_id), ctx)

    results =
      Map.new(objects, fn %{element_id: element_id} ->
        result = Map.put(vqts[element_id], :isComposition, false)

        {element_id,
         case components do
           %{^element_id => :unfetched} ->
             %{result | isComposition: true}

           %{^element_id => found} ->
             found = Map.new(found, &{&1.element_id, vqts[&1.element_id]})
             result |> Map.put(:isComposition, true) |> Map.put(:components, found)

           _ ->
             result
         end}
      end)

    {results, partial?}
  end

  @doc "The current VQT of each Object, by elementId, without its components."
  def vqts(objects, ctx) do
    read =
      objects
      |> Enum.group_by(& &1.source)
      |> Enum.reduce(%{}, fn {{module, opts}, objects}, read ->
        Map.merge(read, module.values(objects, ctx, opts))
      end)

    Map.new(objects, fn %{element_id: element_id} -> {element_id, vqt(read[element_id])} end)
  end

  @doc "A source's value as the API carries it."
  def vqt(nil), do: Value.vqt(nil, nil, nil)
  def vqt(vqt), do: Value.vqt(vqt[:value], vqt[:quality], vqt[:timestamp])

  @doc "Which of the Objects are compositions, as a set of elementIds."
  def compositions(objects, ctx) do
    objects |> edges(ctx, ["HasComponent"]) |> Map.keys() |> MapSet.new()
  end

  # Walks HasComponent one level at a time. `frontier` pairs each object on
  # the current level with the requested Object it descends from.
  defp descend(frontier, level, max_depth, ctx, found) do
    children = frontier |> Enum.map(&elem(&1, 1)) |> edges(ctx, ["HasComponent"])

    next =
      for {root, object} <- frontier,
          {"HasComponent", child} <- Map.get(children, object.element_id, []),
          do: {root, child}

    cond do
      next == [] ->
        {found, false}

      max_depth != 0 and level >= max_depth ->
        {mark_unfetched(found, next), false}

      level >= ctx.max_depth ->
        {mark_unfetched(found, next), true}

      true ->
        found =
          Enum.reduce(next, found, fn {root, child}, found ->
            Map.update(found, root, [child], &[child | &1])
          end)

        descend(next, level + 1, max_depth, ctx, found)
    end
  end

  defp mark_unfetched(found, next) do
    Enum.reduce(next, found, fn {root, _child}, found -> Map.put_new(found, root, :unfetched) end)
  end

  @doc "The historical values of an Object. A source without history has none."
  def history(%Object{source: {module, opts} = source} = object, from, to, ctx) do
    if exports?(source, :history, 5) do
      with {:ok, entries} <- module.history(object, from, to, ctx, opts) do
        {:ok, Enum.map(entries, &Value.vqt(&1.value, &1[:quality], &1.timestamp))}
      end
    else
      {:ok, []}
    end
  end

  def write_history(%Object{source: {module, opts}} = object, entry, ctx),
    do: ok(module.write_history(object, entry, ctx, opts))

  def write(%Object{source: {module, opts}} = object, value, quality, timestamp, ctx),
    do: ok(module.write(object, value, quality, timestamp, ctx, opts))

  defp ok({:ok, _}), do: :ok
  defp ok(other), do: other

  @doc """
  What a subscriber registered with `ctx` is told about a published change
  to the Object of `source` with this elementId: its VQT, or nil.
  """
  def changed({module, opts} = source, element_id, payload, ctx) do
    answer =
      cond do
        exports?(source, :changed, 4) -> module.changed(element_id, payload, ctx, opts)
        is_map(payload) -> {:ok, payload}
        true -> :reread
      end

    case answer do
      {:ok, vqt} ->
        vqt(vqt)

      :reread ->
        case fetch([element_id], %{ctx | sources: [source]}) do
          %{^element_id => object} -> vqts([object], ctx)[element_id]
          _ -> nil
        end

      :skip ->
        nil
    end
  end
end
