defmodule AshI3x.Source do
  @moduledoc """
  Where Object Types and Objects come from when they are not Ash resources
  known at compile time.

  `AshI3x.Resource` turns a resource into one Object Type. A source is for
  the other case: types that are data (a device model stored in a table, a
  class in a graph, a tag list read from a PLC) and differ per tenant. The
  plug asks the source at request time, with the actor and tenant of the
  request, and the source answers in i3X terms.

      defmodule MyApp.I3x.Devices do
        @behaviour AshI3x.Source

        @impl true
        def namespaces(_ctx, _opts), do: [%{uri: "https://example.com/ns/devices", displayName: "Devices"}]

        @impl true
        def object_types(ctx, _opts) do
          for model <- MyApp.Models.list(ctx.tenant) do
            %{
              elementId: model.name <> "Type",
              displayName: model.title,
              namespaceUri: "https://example.com/ns/devices",
              sourceTypeId: model.name,
              schema: MyApp.Models.json_schema(model)
            }
          end
        end

        @impl true
        def list(filter, ctx, _opts), do: ...   # [%AshI3x.Object{}]

        @impl true
        def fetch(element_ids, ctx, _opts), do: ...

        @impl true
        def values(objects, ctx, _opts), do: ...   # %{elementId => %{value: ..., quality: ..., timestamp: ...}}
      end

      forward "/i3x/v1", AshI3x.Plug, sources: [MyApp.I3x.Devices]

  A source may be given as `{module, opts}`; every callback gets those
  `opts` last. `ctx` is a map with at least `:actor` and `:tenant`, as set on
  the conn with `Ash.PlugHelpers`. Authorization is the source's own job: an
  Object the actor may not see is simply not returned.

  Sources and `:domains` can be served together. ElementIds, Object Type ids
  and relationship type ids must be unique across all of them, and a
  relationship stays within its source.

  ## Changes

  Subscriptions learn of a change when the source says so:

      AshI3x.Source.publish(MyApp.I3x.Devices, tenant, "pump-101")

  With only an elementId the subscription reads the Object again, as its
  subscriber, through `c:fetch/3` and `c:values/3`. Passing the new value
  (`%{value: ..., quality: ..., timestamp: ...}`) skips that read; do it only
  when everyone who could register the Object may also see every value of it.

  Publishing reaches subscriptions on every connected node.
  """

  alias AshI3x.Object

  @type ctx :: %{required(:actor) => term, required(:tenant) => term, optional(atom) => term}
  @type opts :: term

  @typedoc "A value as i3X carries it. Quality defaults to Good (GoodNoData without a value), timestamp to now."
  @type vqt :: %{
          required(:value) => term,
          optional(:quality) => String.t() | atom | nil,
          optional(:timestamp) => DateTime.t() | String.t() | nil
        }

  @typedoc """
  What went wrong: `{:invalid, message}` is a 400, `{:forbidden, message}` a
  403, `{:unsupported, message}` a 501. Ash errors keep their class; anything
  else is a 500.
  """
  @type error :: {:invalid | :forbidden | :unsupported, String.t()} | term

  @doc "The Namespaces the source's types live in, as `%{uri: ..., displayName: ...}`."
  @callback namespaces(ctx, opts) :: [map]

  @doc """
  The Object Types, as i3X describes them: `:elementId`, `:displayName`,
  `:namespaceUri`, `:sourceTypeId`, `:schema` (a JSON Schema) and optionally
  `:version`.
  """
  @callback object_types(ctx, opts) :: [map]

  @doc """
  The relationship types beyond the built-in hierarchy, each with its
  reverse: `:elementId`, `:displayName`, `:namespaceUri`, `:relationshipId`
  and `:reverseOf`.
  """
  @callback relationship_types(ctx, opts) :: [map]

  @doc """
  What the source can do beyond reading current values: `:history`, `:write`
  and `:write_history`, each a boolean. Reported by `GET /info`.
  """
  @callback capabilities(ctx, opts) :: %{optional(:history | :write | :write_history) => boolean}

  @doc """
  The Objects, optionally only those of one type (`filter.type`) or those
  without a parent (`filter.root?`). This is browsing: it should not read
  values.
  """
  @callback list(filter :: %{type: String.t() | nil, root?: boolean}, ctx, opts) :: [Object.t()]

  @doc "The Objects with these elementIds. Unknown ones are left out."
  @callback fetch(element_ids :: [String.t()], ctx, opts) :: [Object.t()]

  @doc """
  The Objects related to each of the given ones, as a map of elementId to
  `{relationship type, object}` pairs, in both directions: a child reports
  `HasParent`, its parent `HasChildren`. `only` is `:all` or the relationship
  types wanted. The built-in types are `HasParent`/`HasChildren` and
  `ComponentOf`/`HasComponent`.
  """
  @callback related([Object.t()], only :: :all | [String.t()], ctx, opts) ::
              %{String.t() => [{String.t(), Object.t()}]}

  @doc "The current value of each Object, by elementId. An Object left out has no value."
  @callback values([Object.t()], ctx, opts) :: %{String.t() => vqt}

  @doc "Replaces an Object's current value. Only called for Objects that are `writable?`."
  @callback write(
              Object.t(),
              value :: term,
              quality :: String.t() | nil,
              DateTime.t() | nil,
              ctx,
              opts
            ) ::
              :ok | {:error, error}

  @doc "The Object's values between two instants, inclusive, in the order to return them."
  @callback history(Object.t(), from :: DateTime.t(), to :: DateTime.t(), ctx, opts) ::
              {:ok, [AshI3x.History.entry()]} | {:error, error}

  @doc "Creates or replaces one historical value. Only called for Objects that are `history_writable?`."
  @callback write_history(Object.t(), AshI3x.History.entry(), ctx, opts) :: :ok | {:error, error}

  @doc """
  What a subscriber is told about something published with `publish/4`:
  `{:ok, vqt}` to deliver that value, `:reread` to read the Object again as
  the subscriber, `:skip` to deliver nothing. Without this callback a
  published value is delivered and anything else is read again.
  """
  @callback changed(element_id :: String.t(), payload :: term, ctx, opts) ::
              {:ok, vqt} | :reread | :skip

  @optional_callbacks namespaces: 2,
                      relationship_types: 2,
                      capabilities: 2,
                      related: 4,
                      write: 6,
                      history: 5,
                      write_history: 4,
                      changed: 4

  @doc """
  Tells the subscriptions monitoring an Object of `source` that it changed,
  on this node and every connected one. `tenant` is the Object's `:tenant`:
  the tenant of the requests that can see it, unless the source set another.
  """
  @spec publish(module, tenant :: term, element_id :: String.t(), vqt | :changed) :: :ok
  def publish(source, tenant, element_id, payload \\ :changed) when is_atom(source),
    do: AshI3x.Subscription.notify({source, tenant, element_id}, element_id, payload)
end
