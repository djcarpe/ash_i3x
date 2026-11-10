# AshI3x

An [Ash](https://ash-hq.org) extension that serves your resources over
[i3X](https://i3x.dev), CESMII's common API for industrial information.

A resource becomes an i3X **Object Type**, with a JSON Schema derived from its
attributes. Each record becomes an **Object**. Ash relationships become i3X
**relationships**. One plug then serves the whole i3X 1.0 API: browsing,
current and historical values, writes, and subscriptions over sync or SSE.

Types that are not resources (a device model stored as data, different for
every tenant) are served by a [source](#sources) instead, alone or beside the
resources.

## Installation

```elixir
def deps do
  [
    {:ash_i3x, path: "../ash_i3x"}
  ]
end
```

Add `:ash_i3x` to `import_deps` in `.formatter.exs`.

## Describing resources

```elixir
defmodule MyApp.Plant.Pump do
  use Ash.Resource,
    domain: MyApp.Plant,
    data_layer: AshPostgres.DataLayer,
    extensions: [AshI3x.Resource]

  i3x do
    namespace "https://example.com/ns/equipment"
    display_name :name
    parent :line
    value [:flow_rate, :outlet_temp, :state]
    update_action :update
    relationship :tank, "SuppliesTo", reverse: "SuppliedBy"
  end

  attributes do
    uuid_primary_key :id
    attribute :name, :string, public?: true
    attribute :flow_rate, :float, public?: true, allow_nil?: false
    attribute :outlet_temp, :float, public?: true
    attribute :state, :atom, public?: true, constraints: [one_of: [:running, :stopped]]
    update_timestamp :updated_at
  end

  relationships do
    belongs_to :line, MyApp.Plant.Line
    belongs_to :tank, MyApp.Plant.Tank
  end
end
```

Every option has a default, so `i3x do end` is a valid start.

| Option | What it sets | Default |
| --- | --- | --- |
| `type`, `type_display_name`, `version`, `source_type_id` | The Object Type | `"PumpType"`, `"Pump"` |
| `namespace` | The Namespace URI of the type | the plug's `:namespace` |
| `prefix`, `identifier` | elementIds, as `"<prefix>:<identifier>"` | `"pump"`, the primary key |
| `display_name`, `description` | Attributes describing each Object | the elementId, none |
| `value` | The fields making up the value: a list for a structured value, one name for a scalar | the remaining public attributes |
| `quality`, `timestamp` | Attributes holding the value's quality and time | derived, `:updated_at` or now |
| `parent` | The `belongs_to` giving `HasParent` / `HasChildren` | none, so a root Object |
| `component_of` | The `belongs_to` giving `ComponentOf` / `HasComponent` | none |
| `relationship` | Any other Ash relationship, as a graph relationship with a reverse | none |
| `read_action`, `update_action` | The actions used | primary read; no writes |
| `history` | An `AshI3x.History` module | no history |

Relationships are declared once, on whichever side has the Ash relationship.
The other end reports the reverse without declaring anything, which is what
i3X means by storing relationships bidirectionally.

## Serving

```elixir
# Phoenix router
forward "/i3x/v1", AshI3x.Plug,
  domains: [MyApp.Plant],
  namespace: "https://example.com/ns/plant",
  server_name: "My plant"
```

The specification wants the API under a `/v1` path. See `AshI3x.Plug` for the
rest of the options.

### Authentication and authorization

i3X does not pick an authentication scheme, so neither does this library. Put
your own plug in front, leave `GET /info` open as the specification requires,
and set the actor with `Ash.PlugHelpers.set_actor/2`. Everything then runs as
that actor with `authorize?: true`: an Object the actor's policies hide is a
404, and a subscription only delivers changes its actor may read.

## Sources

A resource is one Object Type, fixed at compile time. When the types are data
(models in a table, classes in a graph, a tag list read from a PLC) implement
`AshI3x.Source`: the plug asks it at request time, with the actor and tenant
of the request, and it answers in i3X terms.

```elixir
defmodule MyApp.I3x.Devices do
  @behaviour AshI3x.Source

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
  def list(%{type: type, root?: root?}, ctx, _opts), do: ...   # [%AshI3x.Object{}]

  @impl true
  def fetch(element_ids, ctx, _opts), do: ...                  # [%AshI3x.Object{}]

  @impl true
  def values(objects, ctx, _opts), do: ...
  # %{"pump-101" => %{value: %{"flow" => 12.5}, quality: "Good", timestamp: ~U[...]}}
end
```

```elixir
forward "/i3x/v1", AshI3x.Plug,
  domains: [MyApp.Plant],            # optional
  sources: [MyApp.I3x.Devices]       # or {MyApp.I3x.Devices, opts}
```

Those three callbacks and `object_types/2` are required. The optional ones add
namespaces, relationships (`related/4`), writes, history and what `GET /info`
reports. `list/3` is browsing and should not read values. Authorization is
the source's: an Object the actor may not see is simply not returned. See
`AshI3x.Source` for every callback.

A source tells subscriptions about a change itself:

```elixir
AshI3x.Source.publish(MyApp.I3x.Devices, tenant, "pump-101")
# or, to skip reading the Object again for each subscriber:
AshI3x.Source.publish(MyApp.I3x.Devices, tenant, "pump-101", %{value: %{"flow" => 12.7}})
```

ElementIds and type ids must be unique across the domains and sources of one
plug, and a relationship stays within its source.

## History

Ash has no notion of history, so `/objects/history` asks a module of yours:

```elixir
defmodule MyApp.Plant.PumpHistory do
  @behaviour AshI3x.History

  @impl true
  def read(pump, from, to, _opts) do
    {:ok, MyApp.Historian.range(pump.id, from, to)}
    # [%{value: %{"flow_rate" => 12.5}, quality: "Good", timestamp: ~U[...]}]
  end
end
```

Implementing the optional `write/3` enables `PUT /objects/history`. Resources
without a history module answer with no values.

## Subscriptions

`AshI3x.Resource` adds a notifier to the resource, so creates and updates made
through Ash actions reach subscribers. Two things do not, unless you help:

- Bulk actions notify only with `notify?: true`.
- Changes made outside Ash need `AshI3x.Subscription.publish/3`.

Subscriptions are processes on the node that created them, and are lost when
it restarts. In a cluster of connected nodes nothing else is needed: a change
published on one node reaches the subscriptions held on the others, and a
sync, stream, register or delete is answered by whichever node receives it.

## Limits

- Composition is only followed for current values. `maxDepth` on history and
  on subscriptions is accepted, and reported back, but each Object delivers
  its own value.
- `GET /objects` reads every Object of every type, since i3X has no paging.
- `isExtended`, `schemaExtensions` and Object Type inheritance (`related`)
  are not produced.

## Conformance

`test/conformance_server.exs` serves the test resources and a test source over HTTP for the
[official conformance suite](https://github.com/cesmii/i3X/tree/1.0/conformance-tests):

```sh
MIX_ENV=test mix run test/conformance_server.exs
node bin/i3x-test.js run http://localhost:4040/v1   # from the suite's folder
```
