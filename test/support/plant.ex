defmodule AshI3x.Test.History do
  @moduledoc false
  @behaviour AshI3x.History

  def start, do: Agent.start_link(fn -> %{} end, name: __MODULE__)

  @impl true
  def read(record, from, to, _opts) do
    entries =
      __MODULE__
      |> Agent.get(&Map.get(&1, record.id, []))
      |> Enum.filter(
        &(DateTime.compare(&1.timestamp, from) != :lt and
            DateTime.compare(&1.timestamp, to) != :gt)
      )
      |> Enum.sort_by(& &1.timestamp, DateTime)

    {:ok, entries}
  end

  @impl true
  def write(record, entry, _opts) do
    Agent.update(__MODULE__, fn history ->
      Map.update(history, record.id, [entry], fn entries ->
        [entry | Enum.reject(entries, &(&1.timestamp == entry.timestamp))]
      end)
    end)
  end
end

defmodule AshI3x.Test.Line do
  @moduledoc false
  use Ash.Resource,
    domain: AshI3x.Test.Plant,
    data_layer: Ash.DataLayer.Ets,
    extensions: [AshI3x.Resource]

  i3x do
    display_name :name
  end

  attributes do
    uuid_primary_key :id
    attribute :name, :string, public?: true, allow_nil?: false
  end

  actions do
    defaults [:read, :destroy, create: :*, update: :*]
  end
end

defmodule AshI3x.Test.Tank do
  @moduledoc false
  use Ash.Resource,
    domain: AshI3x.Test.Plant,
    data_layer: Ash.DataLayer.Ets,
    extensions: [AshI3x.Resource]

  i3x do
    prefix false
    identifier :tag
    parent :line
    value [:level]
  end

  attributes do
    uuid_primary_key :id
    attribute :tag, :string, public?: true, allow_nil?: false
    attribute :level, :float, public?: true
  end

  relationships do
    belongs_to :line, AshI3x.Test.Line, public?: true
  end

  actions do
    defaults [:read, :destroy, create: :*, update: :*]
  end
end

defmodule AshI3x.Test.Pump do
  @moduledoc false
  use Ash.Resource,
    domain: AshI3x.Test.Plant,
    data_layer: Ash.DataLayer.Ets,
    authorizers: [Ash.Policy.Authorizer],
    extensions: [AshI3x.Resource]

  i3x do
    type "PumpType"
    type_display_name "Pump"
    namespace "https://example.com/ns/equipment"
    version "1.0.0"
    display_name :name
    description :notes
    parent :line
    value [:flow_rate, :outlet_temp, :state]
    quality :quality
    update_action :update
    history AshI3x.Test.History
    relationship :tank, "SuppliesTo", reverse: "SuppliedBy"
  end

  attributes do
    uuid_primary_key :id
    attribute :name, :string, public?: true, allow_nil?: false
    attribute :notes, :string, public?: true
    attribute :flow_rate, :float, public?: true, allow_nil?: false
    attribute :outlet_temp, :decimal, public?: true
    attribute :state, :atom, public?: true, constraints: [one_of: [:running, :stopped]]

    attribute :quality, :atom,
      public?: true,
      constraints: [one_of: [:good, :good_no_data, :bad, :uncertain]]

    attribute :secret?, :boolean, public?: true, default: false
    update_timestamp :updated_at
  end

  relationships do
    belongs_to :line, AshI3x.Test.Line, public?: true
    belongs_to :tank, AshI3x.Test.Tank, public?: true
  end

  actions do
    defaults [:read, :destroy, create: :*]

    update :update do
      primary? true
      accept [:flow_rate, :outlet_temp, :state, :quality, :secret?]
    end
  end

  policies do
    policy action_type(:read) do
      authorize_if expr(secret? == false)
      authorize_if actor_attribute_equals(:admin?, true)
    end

    policy action_type([:create, :update, :destroy]) do
      authorize_if always()
    end
  end
end

defmodule AshI3x.Test.Measurement do
  @moduledoc false
  use Ash.Resource,
    domain: AshI3x.Test.Plant,
    data_layer: Ash.DataLayer.Ets,
    extensions: [AshI3x.Resource]

  i3x do
    prefix "meas"
    display_name :name
    component_of :pump
    value :reading
    update_action :update
  end

  attributes do
    uuid_primary_key :id
    attribute :name, :string, public?: true
    attribute :reading, :float, public?: true
  end

  relationships do
    belongs_to :pump, AshI3x.Test.Pump, public?: true
  end

  actions do
    defaults [:read, :destroy, create: :*, update: :*]
  end
end

defmodule AshI3x.Test.Plant do
  @moduledoc false
  use Ash.Domain

  resources do
    resource AshI3x.Test.Line
    resource AshI3x.Test.Tank
    resource AshI3x.Test.Pump
    resource AshI3x.Test.Measurement
  end
end
