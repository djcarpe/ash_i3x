defmodule AshI3xTest do
  use ExUnit.Case, async: false

  import Plug.Conn
  import Plug.Test

  alias AshI3x.Test.{History, Line, Measurement, Pump, Tank}

  @opts [
    domains: [AshI3x.Test.Plant],
    namespace: "https://example.com/ns/plant",
    namespaces: %{"https://example.com/ns/plant" => "Plant"},
    server_name: "test",
    max_depth: 2,
    queue_limit: 3,
    keepalive: 20
  ]

  setup do
    start_supervised!(%{id: History, start: {History, :start, []}})

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

    on_exit(fn ->
      for resource <- [Measurement, Pump, Tank, Line], do: Ash.DataLayer.Ets.stop(resource)
    end)

    %{
      line_id: "line:" <> line.id,
      tank_id: "tank-201",
      pump_id: "pump:" <> pump.id,
      temp_id: "meas:" <> temp.id,
      records: %{line: line, tank: tank, pump: pump, temp: temp}
    }
  end

  defp request(method, path, body \\ nil, opts \\ @opts) do
    conn =
      if body,
        do:
          conn(method, path, Jason.encode!(body))
          |> put_req_header("content-type", "application/json"),
        else: conn(method, path)

    conn = AshI3x.Plug.call(conn, AshI3x.Plug.init(opts))
    {conn.status, Jason.decode!(conn.resp_body)}
  end

  defp get(path), do: request(:get, path)
  defp post(path, body), do: request(:post, path, body)
  defp put(path, body), do: request(:put, path, body)

  defp results(path, body) do
    {200, %{"results" => results}} = post(path, body)
    results
  end

  describe "explore" do
    test "info reports what the resources can do" do
      assert {200, %{"success" => true, "result" => info}} = get("/info")
      assert info["specVersion"] == "1.0"
      assert info["serverName"] == "test"

      assert info["capabilities"] == %{
               "query" => %{"history" => true},
               "update" => %{"current" => true, "history" => true},
               "subscribe" => %{"stream" => true}
             }
    end

    test "namespaces" do
      assert {200, %{"result" => namespaces}} = get("/namespaces")

      assert %{"uri" => "https://example.com/ns/plant", "displayName" => "Plant"} in namespaces
      assert %{"uri" => "https://cesmii.org/i3x", "displayName" => "i3X"} in namespaces
      assert Enum.any?(namespaces, &(&1["uri"] == "https://example.com/ns/equipment"))
    end

    test "object types carry a schema derived from the resource" do
      assert {200, %{"result" => [pump]}} =
               get(
                 "/objecttypes?namespaceUri=" <>
                   URI.encode_www_form("https://example.com/ns/equipment")
               )

      assert %{"elementId" => "PumpType", "displayName" => "Pump", "version" => "1.0.0"} = pump

      assert pump["schema"] == %{
               "type" => "object",
               "required" => ["flow_rate"],
               "properties" => %{
                 "flow_rate" => %{"type" => "number"},
                 "outlet_temp" => %{"type" => ["number", "null"]},
                 "state" => %{"type" => ["string", "null"], "enum" => ["running", "stopped"]}
               }
             }

      assert [%{"success" => true, "result" => leaf}, %{"success" => false} = missing] =
               results("/objecttypes/query", %{elementIds: ["MeasurementType", "Nope"]})

      assert leaf["schema"] == %{"type" => ["number", "null"]}
      assert missing["responseDetail"]["status"] == 404
    end

    test "relationship types come in pairs" do
      assert {200, %{"result" => types}} = get("/relationshiptypes")
      by_id = Map.new(types, &{&1["elementId"], &1})

      assert by_id["HasParent"]["reverseOf"] == "HasChildren"
      assert by_id["SuppliesTo"]["reverseOf"] == "SuppliedBy"
      assert by_id["SuppliedBy"]["namespaceUri"] == "https://example.com/ns/equipment"
      for type <- types, do: assert(is_map_key(by_id, type["reverseOf"]))

      assert [%{"success" => true}] =
               results("/relationshiptypes/query", %{elementIds: ["ComponentOf"]})
    end

    test "objects", ctx do
      assert {200, %{"result" => objects}} = get("/objects")

      assert Enum.map(objects, & &1["elementId"]) ==
               Enum.sort([ctx.line_id, ctx.tank_id, ctx.pump_id, ctx.temp_id])

      assert {200, %{"result" => [root]}} = get("/objects?root=true")

      assert %{"elementId" => ctx.line_id, "displayName" => "Line A", "parentId" => nil} ==
               Map.take(root, ~w(elementId displayName parentId))

      assert {200, %{"result" => [pump]}} =
               get("/objects?typeElementId=PumpType&includeMetadata=true")

      assert %{
               "elementId" => ctx.pump_id,
               "displayName" => "Pump 101",
               "typeElementId" => "PumpType",
               "parentId" => ctx.line_id,
               "isComposition" => true,
               "isExtended" => false,
               "metadata" => %{
                 "description" => "Coolant pump",
                 "typeNamespaceUri" => "https://example.com/ns/equipment",
                 "sourceTypeId" => "PumpType",
                 "relationships" => %{
                   "HasParent" => ctx.line_id,
                   "HasComponent" => [ctx.temp_id],
                   "SuppliesTo" => [ctx.tank_id]
                 }
               }
             } == pump
    end

    test "objects by elementId keep the order asked for", ctx do
      assert [temp, missing, tank] =
               results("/objects/list", %{elementIds: [ctx.temp_id, "pump:nope", ctx.tank_id]})

      assert %{"success" => true, "result" => %{"parentId" => parent, "isComposition" => false}} =
               temp

      assert parent == ctx.pump_id

      assert %{
               "success" => false,
               "elementId" => "pump:nope",
               "responseDetail" => %{"status" => 404}
             } = missing

      assert tank["result"]["displayName"] == "tank-201"
      refute is_map_key(tank["result"], "metadata")
    end

    test "related objects are reachable from either end", ctx do
      assert [%{"result" => from_pump}, %{"result" => from_tank}, %{"result" => from_line}] =
               results("/objects/related", %{elementIds: [ctx.pump_id, ctx.tank_id, ctx.line_id]})

      edges = fn related ->
        related |> Enum.map(&{&1["sourceRelationship"], &1["object"]["elementId"]}) |> Enum.sort()
      end

      assert edges.(from_pump) ==
               Enum.sort([
                 {"HasParent", ctx.line_id},
                 {"HasComponent", ctx.temp_id},
                 {"SuppliesTo", ctx.tank_id}
               ])

      assert edges.(from_tank) ==
               Enum.sort([{"HasParent", ctx.line_id}, {"SuppliedBy", ctx.pump_id}])

      assert edges.(from_line) ==
               Enum.sort([{"HasChildren", ctx.pump_id}, {"HasChildren", ctx.tank_id}])

      assert [%{"result" => [%{"object" => %{"elementId" => tank, "parentId" => line}}]}] =
               results("/objects/related", %{
                 elementIds: [ctx.pump_id],
                 relationshipType: "SuppliesTo"
               })

      assert {tank, line} == {ctx.tank_id, ctx.line_id}
    end

    test "malformed requests are refused" do
      assert {400,
              %{
                "success" => false,
                "responseDetail" => %{"status" => 400, "title" => "Bad Request"}
              }} =
               post("/objects/list", %{})

      assert {404, %{"success" => false}} = get("/nowhere")

      conn =
        conn(:post, "/objects/list", "{") |> put_req_header("content-type", "application/json")

      assert %{status: 400} = AshI3x.Plug.call(conn, AshI3x.Plug.init(@opts))
    end

    test "responses are gzipped on request" do
      conn = conn(:get, "/namespaces") |> put_req_header("accept-encoding", "gzip, br")
      conn = AshI3x.Plug.call(conn, AshI3x.Plug.init(@opts))

      assert get_resp_header(conn, "content-encoding") == ["gzip"]
      assert %{"success" => true} = conn.resp_body |> :zlib.gunzip() |> Jason.decode!()
    end
  end

  describe "values" do
    test "current values", ctx do
      assert [%{"result" => pump}, %{"result" => temp}, %{"result" => line}] =
               results("/objects/value", %{elementIds: [ctx.pump_id, ctx.temp_id, ctx.line_id]})

      assert %{
               "isComposition" => true,
               "quality" => "Good",
               "value" => %{"flow_rate" => 12.5, "outlet_temp" => 40.5, "state" => "running"}
             } = pump

      refute is_map_key(pump, "components")
      assert {:ok, _, 0} = DateTime.from_iso8601(pump["timestamp"])
      assert %{"isComposition" => false, "value" => 70.3, "quality" => "Good"} = temp
      assert %{"value" => nil, "quality" => "GoodNoData"} = line
    end

    test "maxDepth brings components along", ctx do
      temp = ctx.temp_id

      assert [
               %{
                 "result" => %{
                   "components" => %{^temp => %{"value" => 70.3, "quality" => "Good"}}
                 }
               }
             ] =
               results("/objects/value", %{elementIds: [ctx.pump_id], maxDepth: 2})
    end

    test "a read cut short by the server's depth limit is a 206", ctx do
      opts = Keyword.put(@opts, :max_depth, 1)

      assert {206,
              %{
                "success" => true,
                "results" => [%{"result" => result}],
                "responseDetail" => detail
              }} =
               request(:post, "/objects/value", %{elementIds: [ctx.pump_id], maxDepth: 0}, opts)

      assert result["isComposition"]
      assert detail["status"] == 206
    end

    test "writes replace the value through the update action", ctx do
      body = %{
        updates: [
          %{
            elementId: ctx.pump_id,
            value: %{value: %{flow_rate: 3.0, state: "stopped"}, quality: "Uncertain"}
          },
          %{elementId: ctx.temp_id, value: %{value: 71.0}},
          %{elementId: ctx.pump_id, value: %{value: %{flow_rate: "fast"}}},
          %{elementId: ctx.pump_id, value: %{value: %{name: "renamed", flow_rate: 1.0}}},
          %{elementId: ctx.tank_id, value: %{value: %{level: 1.0}}},
          %{elementId: "pump:nope", value: %{value: 1}}
        ]
      }

      assert {200, %{"success" => false, "results" => results}} = put("/objects/value", body)

      assert Enum.map(results, &(&1["success"] || &1["responseDetail"]["status"])) == [
               true,
               true,
               400,
               400,
               501,
               404
             ]

      assert hd(results)["result"] == nil

      assert [%{"result" => pump}, %{"result" => temp}] =
               results("/objects/value", %{elementIds: [ctx.pump_id, ctx.temp_id]})

      assert pump["value"] == %{"flow_rate" => 3.0, "outlet_temp" => nil, "state" => "stopped"}
      assert pump["quality"] == "Uncertain"
      assert temp["value"] == 71.0
    end

    test "history is read and written through the history module", ctx do
      range = %{startTime: "2025-01-01T00:00:00Z", endTime: "2025-01-02T00:00:00Z"}

      assert [
               %{"result" => %{"isComposition" => true, "values" => []}},
               %{"result" => %{"values" => []}}
             ] =
               results(
                 "/objects/history",
                 Map.put(range, :elementIds, [ctx.pump_id, ctx.tank_id])
               )

      vqt = fn time, flow -> %{value: %{flow_rate: flow}, quality: "Good", timestamp: time} end

      assert {200,
              %{
                "results" => [
                  %{"success" => true},
                  %{"success" => true},
                  %{"success" => true},
                  tank
                ]
              }} =
               put("/objects/history", %{
                 updates: [
                   %{elementId: ctx.pump_id, value: vqt.("2025-01-01T08:00:00Z", 2.0)},
                   %{elementId: ctx.pump_id, value: vqt.("2025-01-01T07:00:00Z", 1.0)},
                   %{elementId: ctx.pump_id, value: vqt.("2025-03-01T00:00:00Z", 9.0)},
                   %{elementId: ctx.tank_id, value: vqt.("2025-01-01T07:00:00Z", 1.0)}
                 ]
               })

      assert tank["responseDetail"]["status"] == 501

      assert [%{"result" => %{"values" => values}}] =
               results("/objects/history", Map.put(range, :elementIds, [ctx.pump_id]))

      assert values == [
               %{
                 "value" => %{"flow_rate" => 1.0},
                 "quality" => "Good",
                 "timestamp" => "2025-01-01T07:00:00Z"
               },
               %{
                 "value" => %{"flow_rate" => 2.0},
                 "quality" => "Good",
                 "timestamp" => "2025-01-01T08:00:00Z"
               }
             ]

      assert {400, _} =
               post("/objects/history", %{elementIds: [ctx.pump_id], startTime: "yesterday"})

      assert {400, _} =
               put("/objects/history", %{updates: [%{elementId: ctx.pump_id, value: %{value: 1}}]})
    end
  end

  describe "authorization" do
    test "objects the actor cannot read do not exist", ctx do
      Ash.update!(ctx.records.pump, %{secret?: true})

      assert [%{"success" => false, "responseDetail" => %{"status" => 404}}] =
               results("/objects/list", %{elementIds: [ctx.pump_id]})

      assert [%{"result" => []}] = results("/objects/related", %{elementIds: [ctx.temp_id]})

      admin = fn conn -> Ash.PlugHelpers.set_actor(conn, %{admin?: true}) end

      conn =
        conn(:post, "/objects/list", Jason.encode!(%{elementIds: [ctx.pump_id]}))
        |> put_req_header("content-type", "application/json")
        |> admin.()
        |> AshI3x.Plug.call(AshI3x.Plug.init(@opts))

      assert %{"results" => [%{"success" => true}]} = Jason.decode!(conn.resp_body)
    end
  end

  describe "subscriptions" do
    defp subscribe(ids, client \\ "client-1") do
      assert {200,
              %{
                "result" => %{
                  "subscriptionId" => id,
                  "clientId" => ^client,
                  "displayName" => "mine"
                }
              }} =
               post("/subscriptions", %{clientId: client, displayName: "mine"})

      sub = %{clientId: client, subscriptionId: id}
      results("/subscriptions/register", Map.put(sub, :elementIds, ids))
      sub
    end

    defp sync(sub, last \\ nil) do
      post(
        "/subscriptions/sync",
        if(last, do: Map.put(sub, :lastSequenceNumber, last), else: sub)
      )
    end

    test "register, list, unregister and delete", ctx do
      sub = subscribe([])

      assert [
               %{"success" => true, "result" => nil},
               %{"success" => false, "responseDetail" => %{"status" => 404}}
             ] =
               results(
                 "/subscriptions/register",
                 Map.merge(sub, %{elementIds: [ctx.temp_id, "meas:nope"], maxDepth: 0})
               )

      assert [%{"success" => true}] =
               results("/subscriptions/register", Map.put(sub, :elementIds, [ctx.temp_id]))

      list = %{clientId: sub.clientId, subscriptionIds: [sub.subscriptionId, "unknown"]}

      assert [
               %{"success" => true, "subscriptionId" => id, "result" => info},
               %{"success" => false}
             ] =
               results("/subscriptions/list", list)

      assert id == sub.subscriptionId

      assert info == %{
               "subscriptionId" => id,
               "displayName" => "mine",
               "monitoredObjects" => [%{"elementId" => ctx.temp_id, "maxDepth" => 0}]
             }

      assert [%{"success" => true}, %{"success" => false}] =
               results(
                 "/subscriptions/unregister",
                 Map.put(sub, :elementIds, [ctx.temp_id, ctx.pump_id])
               )

      assert [%{"success" => true, "result" => nil}, %{"success" => false}] =
               results("/subscriptions/delete", list)

      assert [%{"success" => false}, _] = results("/subscriptions/list", list)
      assert {404, _} = sync(sub)
    end

    test "a subscription belongs to its client", ctx do
      sub = subscribe([ctx.temp_id])

      assert {404, _} = sync(%{sub | clientId: "client-2"})
      assert {400, _} = post("/subscriptions/sync", Map.delete(sub, :clientId))
      assert {400, _} = post("/subscriptions", %{})
    end

    test "sync hands out batches until they are acknowledged", ctx do
      sub = subscribe([ctx.temp_id, ctx.pump_id])
      temp = ctx.temp_id

      assert {200, %{"success" => true, "result" => []}} = sync(sub)

      Ash.update!(ctx.records.temp, %{reading: 1.0})
      Ash.update!(ctx.records.line, %{name: "ignored"})

      assert {200, %{"result" => [%{"sequenceNumber" => 1, "updates" => [update]}]}} = sync(sub)

      assert %{"elementId" => ^temp, "value" => 1.0, "quality" => "Good", "timestamp" => _} =
               update

      Ash.update!(ctx.records.pump, %{flow_rate: 2.0})

      assert {200,
              %{
                "result" => [
                  %{"sequenceNumber" => 1},
                  %{"sequenceNumber" => 2, "updates" => [pump]}
                ]
              }} = sync(sub)

      assert pump["value"]["flow_rate"] == 2.0

      assert {200, %{"result" => [%{"sequenceNumber" => 2}]}} = sync(sub, 1)
      assert {200, %{"result" => []}} = sync(sub, 2)

      Ash.update!(ctx.records.temp, %{reading: 2.0})
      assert {200, %{"result" => []}} = sync(sub, -1)
    end

    test "changes the subscriber may not read are not delivered", ctx do
      sub = subscribe([ctx.pump_id])

      Ash.update!(ctx.records.pump, %{secret?: true, flow_rate: 99.0})
      assert {200, %{"result" => []}} = sync(sub)
    end

    test "an overflowing queue drops the oldest updates and says so", ctx do
      sub = subscribe([ctx.temp_id])
      for reading <- 1..5, do: Ash.update!(ctx.records.temp, %{reading: reading * 1.0})

      assert {206,
              %{
                "success" => true,
                "result" => [%{"updates" => updates}],
                "responseDetail" => %{"status" => 206}
              }} =
               sync(sub)

      assert Enum.map(updates, & &1["value"]) == [3.0, 4.0, 5.0]
      assert {200, _} = sync(sub, 1)
    end

    test "an idle subscription expires", ctx do
      opts = Keyword.put(@opts, :subscription_ttl, 30)

      {200, %{"result" => %{"subscriptionId" => id}}} =
        request(:post, "/subscriptions", %{clientId: "c"}, opts)

      sub = %{clientId: "c", subscriptionId: id, elementIds: [ctx.temp_id]}

      assert {200, _} = request(:post, "/subscriptions/sync", sub, opts)
      Process.sleep(80)
      assert {404, _} = request(:post, "/subscriptions/sync", sub, opts)
    end

    test "a stream delivers queued and live updates, and only one may be open", ctx do
      sub = subscribe([ctx.temp_id])
      Ash.update!(ctx.records.temp, %{reading: 1.0})

      open = fn ->
        Task.async(fn ->
          conn(:post, "/subscriptions/stream", Jason.encode!(sub))
          |> put_req_header("content-type", "application/json")
          |> AshI3x.Plug.call(AshI3x.Plug.init(@opts))
        end)
      end

      first = open.()
      Process.sleep(50)

      assert {400, _} = sync(sub)
      Ash.update!(ctx.records.temp, %{reading: 2.0})
      Process.sleep(50)

      second = open.()
      conn = Task.await(first)

      assert conn.status == 200
      assert get_resp_header(conn, "content-type") == ["text/event-stream; charset=utf-8"]

      events =
        for "data: " <> json <- String.split(conn.resp_body, "\n\n"),
            update <- Jason.decode!(json),
            do: update["value"]

      assert events == [1.0, 2.0]
      assert conn.resp_body =~ ": keepalive"

      assert [%{"success" => true}] =
               results("/subscriptions/delete", %{
                 clientId: sub.clientId,
                 subscriptionIds: [sub.subscriptionId]
               })

      assert %{status: 200} = Task.await(second)
    end
  end

  describe "verification" do
    test "the section is checked at compile time" do
      warnings =
        ExUnit.CaptureIO.capture_io(:stderr, fn ->
          defmodule Broken do
            use Ash.Resource,
              domain: nil,
              extensions: [AshI3x.Resource],
              validate_domain_inclusion?: false

            i3x do
              parent :nothing
            end

            attributes do
              uuid_primary_key :id
            end

            actions do
              defaults [:read]
            end
          end
        end)

      assert warnings =~ ":nothing is not a belongs_to relationship"
    end
  end
end
