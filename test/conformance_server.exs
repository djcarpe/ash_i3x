# Serves the test plant over HTTP so the official i3X conformance suite
# (https://github.com/cesmii/i3X/tree/1.0/conformance-tests) can be run
# against this library:
#
#     MIX_ENV=test mix run test/conformance_server.exs
#     node bin/i3x-test.js run http://localhost:4040/v1

alias AshI3x.Test.{History, Line, Measurement, Pump, Tank}

defmodule AshI3x.Test.Server do
  use Plug.Router

  plug :match
  plug :dispatch

  forward "/v1",
    to: AshI3x.Plug,
    init_opts: [
      domains: [AshI3x.Test.Plant],
      namespace: "https://example.com/ns/plant",
      namespaces: %{"https://example.com/ns/plant" => "Plant"},
      server_name: "ash_i3x conformance",
      server_version: to_string(Application.spec(:ash_i3x, :vsn))
    ]

  match _ do
    send_resp(conn, 404, "")
  end
end

{:ok, _} = History.start()

line = Ash.create!(Line, %{name: "Line A"})
tank = Ash.create!(Tank, %{tag: "tank-201", level: 4.5, line_id: line.id})

pump =
  Ash.create!(Pump, %{
    name: "Pump 101",
    notes: "Coolant pump",
    flow_rate: 12.5,
    outlet_temp: Decimal.new("40.5"),
    state: :running,
    line_id: line.id,
    tank_id: tank.id
  })

temp = Ash.create!(Measurement, %{name: "Bearing temp", reading: 70.3, pump_id: pump.id})

# Something has to change for subscriptions to have anything to deliver.
spawn(fn ->
  Stream.interval(500)
  |> Enum.each(fn tick ->
    Ash.update!(temp, %{reading: 70.0 + rem(tick, 10) / 10})
    Ash.update!(pump, %{flow_rate: 12.0 + rem(tick, 5) / 10})
  end)
end)

{:ok, _} = Bandit.start_link(plug: AshI3x.Test.Server, port: 4040)
IO.puts("i3X at http://localhost:4040/v1")

# Everything above is linked to this process, so it has to stay.
Process.sleep(:infinity)
