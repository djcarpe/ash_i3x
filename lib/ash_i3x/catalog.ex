defmodule AshI3x.Catalog do
  @moduledoc false

  # The address space the domains describe: one exposure per resource, the
  # relationship types between them, and the namespaces they live in.

  alias AshI3x.JsonSchema
  alias AshI3x.Resource.Info

  @i3x_namespace "https://cesmii.org/i3x"
  @hierarchy [{"HasParent", "HasChildren"}, {"ComponentOf", "HasComponent"}]

  defmodule Exposure do
    @moduledoc false
    defstruct [
      :resource,
      :domain,
      :type,
      :type_display_name,
      :namespace,
      :version,
      :source_type_id,
      :prefix,
      :identifier,
      :display_name,
      :description,
      :fields,
      :scalar?,
      :loads,
      :quality,
      :timestamp,
      :read_action,
      :update_action,
      :history,
      :edges,
      :schema,
      :reread?
    ]
  end

  defstruct [:exposures, :types, :relationship_types, :namespaces, :inbound]

  @doc "The catalog for these domains, rebuilt when any of their resources is recompiled."
  def get(domains, opts) do
    resources =
      for domain <- domains,
          resource <- Ash.Domain.Info.resources(domain),
          Info.exposed?(resource),
          do: {resource, domain}

    key = {__MODULE__, opts[:namespace], opts[:namespaces], fingerprint(resources)}

    case :persistent_term.get(key, nil) do
      nil ->
        catalog = build(resources, opts)
        :persistent_term.put(key, catalog)
        catalog

      catalog ->
        catalog
    end
  end

  @doc "The exposures an elementId could belong to, each with the identifier left to look up."
  def locate(%__MODULE__{exposures: exposures}, element_id) do
    for {_resource, exposure} <- exposures, key <- key(exposure, element_id), do: {exposure, key}
  end

  defp key(%{prefix: nil}, element_id), do: [element_id]

  defp key(%{prefix: prefix}, element_id) do
    case element_id do
      <<^prefix::binary, ":", key::binary>> -> [key]
      _ -> []
    end
  end

  defp fingerprint(resources) do
    :erlang.phash2(for {resource, domain} <- resources, do: {domain, resource.module_info(:md5)})
  end

  defp build(resources, opts) do
    exposed = Map.new(resources)
    exposures = Enum.map(resources, &exposure(&1, exposed, opts))

    unique!(exposures, & &1.type, "Object Type")
    unique!(Enum.filter(exposures, & &1.prefix), & &1.prefix, "prefix")

    %__MODULE__{
      exposures: Map.new(exposures, &{&1.resource, &1}),
      types: Map.new(exposures, &{&1.type, &1}),
      relationship_types: relationship_types(exposures),
      namespaces: namespaces(exposures, opts),
      inbound:
        Enum.group_by(
          for(exposure <- exposures, edge <- exposure.edges, do: {exposure, edge}),
          fn {_exposure, edge} -> edge.destination end
        )
    }
  end

  defp exposure({resource, domain}, exposed, opts) do
    {names, scalar?} = Info.value(resource)
    fields = Enum.map(names, &Ash.Resource.Info.field(resource, &1))
    loads = for %struct{name: name} <- fields, struct != Ash.Resource.Attribute, do: name

    %Exposure{
      resource: resource,
      domain: domain,
      type: Info.type(resource),
      type_display_name: Info.type_display_name(resource),
      namespace:
        Info.namespace(resource) || opts[:namespace] ||
          raise(ArgumentError, """
          #{inspect(resource)} has no i3X namespace. Set `namespace` in its `i3x` \
          section, or pass a default `:namespace` to AshI3x.Plug.
          """),
      version: Info.version(resource),
      source_type_id: Info.source_type_id(resource),
      prefix: Info.prefix(resource),
      identifier: Info.identifier(resource),
      display_name: Info.display_name(resource),
      description: Info.description(resource),
      fields: names,
      scalar?: scalar?,
      loads: loads,
      quality: Info.quality(resource),
      timestamp: Info.timestamp(resource),
      read_action: Info.read_action(resource),
      update_action: Info.update_action(resource),
      history: Info.history(resource),
      edges: edges(resource, exposed),
      schema: schema(fields, scalar?),
      # A change can be handed to a subscriber as notified only when there is
      # nothing to authorize and nothing to load.
      reread?: loads != [] or Ash.Resource.Info.authorizers(resource) != []
    }
  end

  defp schema([field], true), do: JsonSchema.field(field)
  defp schema([], false), do: %{"type" => "object"}
  defp schema(fields, false), do: JsonSchema.object(fields)

  defp edges(resource, exposed) do
    hierarchy =
      for {name, {type, reverse}} <-
            Enum.zip([Info.parent(resource), Info.component_of(resource)], @hierarchy),
          name,
          do: {name, type, reverse}

    graph = for r <- Info.relationships(resource), do: {r.relationship, r.type, r.reverse}

    for {name, type, reverse} <- hierarchy ++ graph do
      relationship = Ash.Resource.Info.relationship(resource, name)

      is_map_key(exposed, relationship.destination) ||
        raise ArgumentError, """
        #{inspect(resource)} exposes #{inspect(name)} over i3X, but its destination \
        #{inspect(relationship.destination)} is not an AshI3x.Resource in the served domains.
        """

      %{
        relationship: relationship,
        type: type,
        reverse: reverse,
        destination: relationship.destination
      }
    end
  end

  defp relationship_types(exposures) do
    builtin =
      for {type, reverse} <- @hierarchy,
          {id, reverse_of} <- [{type, reverse}, {reverse, type}],
          do: relationship_type(id, reverse_of, @i3x_namespace)

    graph =
      for exposure <- exposures,
          edge <- exposure.edges,
          {id, reverse_of} <- [{edge.type, edge.reverse}, {edge.reverse, edge.type}],
          do: relationship_type(id, reverse_of, exposure.namespace)

    Enum.uniq_by(builtin ++ graph, & &1.elementId)
  end

  defp relationship_type(id, reverse_of, namespace) do
    %{
      elementId: id,
      displayName: id,
      namespaceUri: namespace,
      relationshipId: id,
      reverseOf: reverse_of
    }
  end

  defp namespaces(exposures, opts) do
    names = Map.merge(%{@i3x_namespace => "i3X"}, Map.new(opts[:namespaces] || %{}))

    for uri <- Enum.uniq([@i3x_namespace | Enum.map(exposures, & &1.namespace)]) do
      %{uri: uri, displayName: Map.get(names, uri, uri)}
    end
  end

  defp unique!(exposures, fun, what) do
    for {value, [_, _ | _] = clash} <- Enum.group_by(exposures, fun) do
      raise ArgumentError,
            "i3X #{what} #{inspect(value)} is used by more than one resource: " <>
              Enum.map_join(clash, ", ", &inspect(&1.resource))
    end
  end
end
