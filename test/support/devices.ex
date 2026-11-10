defmodule AshI3x.Test.Devices do
  @moduledoc false

  # A source whose types and objects are data, per tenant: what an
  # `AshI3x.Source` is for. The data lives in an Agent:
  #
  #     %{tenant => %{models: %{name => %{points: %{name => json type}}},
  #                   devices: %{id => %{model:, site:, values:, at:, history: [], hidden_from: []}},
  #                   sites: [id]}}

  @behaviour AshI3x.Source

  alias AshI3x.Object

  @namespace "https://example.com/ns/devices"

  @t0 ~U[2026-01-01 00:00:00Z]

  def start(data), do: Agent.start_link(fn -> data end, name: __MODULE__)

  @doc "Two tenants: one with a model, a site and two devices, one with only a model."
  def sample do
    %{
      "acme" => %{
        models: %{"Filler" => %{points: %{"speed" => "number", "running" => "boolean"}}},
        sites: ["hall-1"],
        devices: %{
          "filler-1" => %{
            model: "Filler",
            site: "hall-1",
            description: "Line 3 filler",
            values: %{"speed" => 40.0, "running" => true},
            at: @t0,
            history: [
              %{value: %{"speed" => 10.0}, timestamp: @t0},
              %{value: %{"speed" => 20.0}, quality: "Uncertain", timestamp: DateTime.add(@t0, 60)}
            ]
          },
          "filler-2" => %{
            model: "Filler",
            site: "hall-1",
            values: %{},
            at: nil,
            writable?: false,
            hidden_from: [:guest]
          }
        }
      },
      "other" => %{
        models: %{"Oven" => %{points: %{"temp" => "number"}}},
        sites: [],
        devices: %{}
      }
    }
  end

  @doc "Changes a device's values the way a driver would, and says so."
  def set(tenant, id, values, opts \\ []) do
    Agent.update(__MODULE__, fn data ->
      update_in(data, [tenant, :devices, id], fn device ->
        %{device | values: Map.merge(device.values, values), at: DateTime.utc_now()}
      end)
    end)

    payload =
      if opts[:with_value],
        do: values(fetch([id], ctx(tenant), []), nil, [])[id],
        else: :changed

    AshI3x.Source.publish(__MODULE__, tenant, id, payload)
  end

  defp ctx(tenant), do: %{actor: nil, tenant: tenant}

  defp tenant(ctx),
    do: Agent.get(__MODULE__, &Map.get(&1, ctx.tenant, %{models: %{}, devices: %{}, sites: []}))

  @impl true
  def namespaces(_ctx, _opts), do: [%{uri: @namespace, displayName: "Devices"}]

  @impl true
  def object_types(ctx, _opts) do
    site = %{
      elementId: "SiteType",
      displayName: "Site",
      namespaceUri: @namespace,
      sourceTypeId: "SiteType",
      schema: %{"type" => "object"}
    }

    models =
      for {name, model} <- tenant(ctx).models do
        %{
          elementId: name <> "Type",
          displayName: name,
          namespaceUri: @namespace,
          sourceTypeId: name,
          version: "1.0.0",
          schema: %{
            "type" => "object",
            "properties" =>
              Map.new(model.points, fn {point, type} -> {point, %{"type" => type}} end)
          }
        }
      end

    [site | models]
  end

  @impl true
  def relationship_types(_ctx, _opts), do: []

  @impl true
  def capabilities(_ctx, _opts), do: %{history: true, write: true, write_history: false}

  @impl true
  def list(%{type: type, root?: root?}, ctx, _opts) do
    data = tenant(ctx)

    sites = for id <- data.sites, type in [nil, "SiteType"], do: site(id)

    devices =
      for {id, device} <- data.devices,
          visible?(device, ctx),
          not root?,
          type in [nil, device.model <> "Type"],
          do: device(id, device)

    sites ++ devices
  end

  @impl true
  def fetch(element_ids, ctx, _opts) do
    data = tenant(ctx)

    Enum.flat_map(element_ids, fn id ->
      cond do
        id in data.sites -> [site(id)]
        (device = data.devices[id]) && visible?(device, ctx) -> [device(id, device)]
        true -> []
      end
    end)
  end

  @impl true
  def related(objects, only, ctx, _opts) do
    data = tenant(ctx)

    Map.new(objects, fn
      %{element_id: id, data: :site} ->
        {id,
         for(
           {child, device} <- data.devices,
           device.site == id,
           visible?(device, ctx),
           wanted?(only, "HasChildren"),
           do: {"HasChildren", device(child, device)}
         )}

      %{element_id: id, data: device} ->
        {id, if(wanted?(only, "HasParent"), do: [{"HasParent", site(device.site)}], else: [])}
    end)
  end

  @impl true
  def values(objects, _ctx, _opts) do
    for %{element_id: id, data: %{} = device} <- objects, into: %{} do
      {id, %{value: device.values, quality: device[:quality], timestamp: device.at}}
    end
  end

  @impl true
  def write(%{element_id: id}, value, _quality, _timestamp, ctx, _opts) when is_map(value) do
    if Map.get(value, "speed", 0) > 100 do
      {:error, {:forbidden, "speed is limited to 100"}}
    else
      set(ctx.tenant, id, value)
    end
  end

  def write(_object, _value, _quality, _timestamp, _ctx, _opts),
    do: {:error, {:invalid, "the value must be an object"}}

  @impl true
  def history(%{data: %{history: entries}}, from, to, _ctx, _opts) do
    {:ok,
     Enum.filter(entries, fn entry ->
       DateTime.compare(entry.timestamp, from) != :lt and
         DateTime.compare(entry.timestamp, to) != :gt
     end)}
  end

  def history(_object, _from, _to, _ctx, _opts), do: {:ok, []}

  defp site(id),
    do: %Object{
      element_id: id,
      type: "SiteType",
      namespace: @namespace,
      display_name: "Site " <> id,
      data: :site
    }

  defp device(id, device) do
    %Object{
      element_id: id,
      type: device.model <> "Type",
      namespace: @namespace,
      source_type_id: device.model,
      description: device[:description],
      writable?: device[:writable?] != false,
      data: device
    }
  end

  defp visible?(device, ctx), do: ctx.actor not in Map.get(device, :hidden_from, [])
  defp wanted?(:all, _type), do: true
  defp wanted?(only, type), do: type in only
end
