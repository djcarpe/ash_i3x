# AshI3x

An [Ash](https://ash-hq.org) extension that serves your resources over
[i3X](https://i3x.dev), CESMII's common API for industrial information.

A resource becomes an i3X **Object Type**, with a JSON Schema derived from its
attributes. Each record becomes an **Object**. Ash relationships become i3X
**relationships**. One plug then serves the whole i3X 1.0 API: browsing,
current and historical values, writes, and subscriptions over sync or SSE.

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

Subscriptions are processes on the node that created them. They are lost on
restart, and in a cluster a client must keep reaching the same node.

## Limits

- Composition is only followed for current values. `maxDepth` on history and
  on subscriptions is accepted, and reported back, but each Object delivers
  its own value.
- `GET /objects` reads every Object of every type, since i3X has no paging.
- `isExtended`, `schemaExtensions` and Object Type inheritance (`related`)
  are not produced.

## Conformance

`test/conformance_server.exs` serves the test resources over HTTP for the
[official conformance suite](https://github.com/cesmii/i3X/tree/1.0/conformance-tests):

```sh
MIX_ENV=test mix run test/conformance_server.exs
node bin/i3x-test.js run http://localhost:4040/v1   # from the suite's folder
```
