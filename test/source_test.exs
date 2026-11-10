defmodule AshI3x.SourceTest do
  use ExUnit.Case, async: false

  import Plug.Conn
  import Plug.Test

  alias AshI3x.Test.Devices

  @opts [sources: [Devices], server_name: "test", queue_limit: 3, keepalive: 20]
  setup do
    start_supervised!(%{id: Devices, start: {Devices, :start, [Devices.sample()]}})
    :ok
  end

  defp request(method, path, body \\ nil, as \\ []) do
    conn =
      if body,
        do:
          conn(method, path, Jason.encode!(body))
          |> put_req_header("content-type", "application/json"),
        else: conn(method, path)

    conn =
      conn
      |> Ash.PlugHelpers.set_tenant(Keyword.get(as, :tenant, "acme"))
      |> Ash.PlugHelpers.set_actor(Keyword.get(as, :actor, :operator))
      |> AshI3x.Plug.call(AshI3x.Plug.init(Keyword.get(as, :opts, @opts)))

    {conn.status, Jason.decode!(conn.resp_body)}
  end

  defp result(response) do
    assert {200, %{"success" => true, "result" => result}} = response
    result
  end

  defp results(response) do
    assert {200, %{"results" => results}} = response
    results
  end

  defp subscribe(ids, as \\ []) do
    %{"subscriptionId" => id} =
      result(request(:post, "/subscriptions", %{"clientId" => "c1"}, as))

    key = %{"clientId" => "c1", "subscriptionId" => id}
    request(:post, "/subscriptions/register", Map.put(key, "elementIds", ids), as)
    key
  end

  defp sync(key, as \\ []) do
    for %{"updates" => updates} <-
          result(request(:post, "/subscriptions/sync", key, as)),
        update <- updates,
        do: update
  end

  test "a plug needs domains or sources" do
    assert_raise ArgumentError, ~r/:domains or :sources/, fn -> AshI3x.Plug.init([]) end
  end

  test "info, namespaces and types come from the source, per tenant" do
    assert %{
             "capabilities" => %{
               "query" => %{"history" => true},
               "update" => %{"current" => true, "history" => false}
             }
           } = result(request(:get, "/info"))

    assert [
             %{"uri" => "https://cesmii.org/i3x"},
             %{"uri" => "https://example.com/ns/devices", "displayName" => "Devices"}
           ] = result(request(:get, "/namespaces"))

    assert [
             %{
               "elementId" => "FillerType",
               "sourceTypeId" => "Filler",
               "version" => "1.0.0",
               "schema" => %{"properties" => %{"speed" => %{"type" => "number"}}}
             },
             %{"elementId" => "SiteType"}
           ] = result(request(:get, "/objecttypes"))

    assert ["OvenType", "SiteType"] =
             request(:get, "/objecttypes", nil, tenant: "other")
             |> result()
             |> Enum.map(& &1["elementId"])

    assert [%{"success" => true}, %{"success" => false}] =
             results(
               request(:post, "/objecttypes/query", %{"elementIds" => ["FillerType", "OvenType"]})
             )

    assert ~w(HasParent HasChildren ComponentOf HasComponent) ==
             request(:get, "/relationshiptypes") |> result() |> Enum.map(& &1["elementId"])
  end

  test "objects are browsed without resources" do
    assert ~w(filler-1 filler-2 hall-1) ==
             request(:get, "/objects") |> result() |> Enum.map(& &1["elementId"])

    assert ["hall-1"] ==
             request(:get, "/objects?root=true") |> result() |> Enum.map(& &1["elementId"])

    assert [
             %{
               "elementId" => "filler-1",
               "displayName" => "filler-1",
               "typeElementId" => "FillerType",
               "parentId" => "hall-1",
               "isComposition" => false,
               "metadata" => %{
                 "typeNamespaceUri" => "https://example.com/ns/devices",
                 "sourceTypeId" => "Filler",
                 "description" => "Line 3 filler",
                 "relationships" => %{"HasParent" => "hall-1"}
               }
             },
             _
           ] = result(request(:get, "/objects?typeElementId=FillerType&includeMetadata=true"))

    assert [%{"result" => children}] =
             results(request(:post, "/objects/related", %{"elementIds" => ["hall-1"]}))

    assert ~w(filler-1 filler-2) ==
             children |> Enum.map(& &1["object"]["elementId"]) |> Enum.sort()

    assert Enum.all?(children, &(&1["sourceRelationship"] == "HasChildren"))
  end

  test "what the actor may not see, and other tenants' objects, do not exist" do
    assert ~w(filler-1 hall-1) ==
             request(:get, "/objects", nil, actor: :guest)
             |> result()
             |> Enum.map(& &1["elementId"])

    assert [%{"success" => false, "responseDetail" => %{"status" => 404}}] =
             results(
               request(:post, "/objects/value", %{"elementIds" => ["filler-2"]}, actor: :guest)
             )

    assert [] == result(request(:get, "/objects", nil, tenant: "other"))

    assert [%{"success" => false}] =
             results(
               request(:post, "/objects/list", %{"elementIds" => ["filler-1"]}, tenant: "other")
             )
  end

  test "values, with quality and timestamp filled in" do
    assert [
             %{
               "result" => %{
                 "value" => %{"speed" => 40.0, "running" => true},
                 "quality" => "Good",
                 "timestamp" => "2026-01-01T00:00:00Z",
                 "isComposition" => false
               }
             },
             %{"result" => %{"value" => %{}, "quality" => "Good"}},
             %{"result" => %{"value" => nil, "quality" => "GoodNoData"}}
           ] =
             results(
               request(:post, "/objects/value", %{
                 "elementIds" => ["filler-1", "filler-2", "hall-1"]
               })
             )
  end

  test "writes go through the source, which may refuse them" do
    write = fn id, value ->
      request(:put, "/objects/value", %{
        "updates" => [%{"elementId" => id, "value" => %{"value" => value}}]
      })
    end

    assert [%{"success" => true}] = results(write.("filler-1", %{"speed" => 55.0}))

    assert [%{"result" => %{"value" => %{"speed" => 55.0, "running" => true}}}] =
             results(request(:post, "/objects/value", %{"elementIds" => ["filler-1"]}))

    assert [%{"responseDetail" => %{"status" => 403, "detail" => "speed is limited to 100"}}] =
             results(write.("filler-1", %{"speed" => 500}))

    assert [%{"responseDetail" => %{"status" => 400}}] = results(write.("filler-1", 3))
    assert [%{"responseDetail" => %{"status" => 501}}] = results(write.("filler-2", %{}))
    assert [%{"responseDetail" => %{"status" => 404}}] = results(write.("nope", %{}))
  end

  test "history is the source's, and writing it is refused when no source can" do
    assert [
             %{
               "result" => %{
                 "values" => [
                   %{"value" => %{"speed" => 10.0}, "quality" => "Good"},
                   %{"value" => %{"speed" => 20.0}, "quality" => "Uncertain"}
                 ]
               }
             },
             %{"result" => %{"values" => []}}
           ] =
             results(
               request(:post, "/objects/history", %{
                 "elementIds" => ["filler-1", "hall-1"],
                 "startTime" => "2026-01-01T00:00:00Z",
                 "endTime" => "2026-01-01T01:00:00Z"
               })
             )

    assert {501, _} =
             request(:put, "/objects/history", %{
               "updates" => [
                 %{
                   "elementId" => "filler-1",
                   "value" => %{
                     "value" => 1,
                     "quality" => "Good",
                     "timestamp" => "2026-01-01T00:00:00Z"
                   }
                 }
               ]
             })
  end

  describe "subscriptions" do
    test "a published change is read again as the subscriber" do
      key = subscribe(["filler-1", "filler-2"])
      guest = subscribe(["filler-1", "filler-2"], actor: :guest)

      Devices.set("acme", "filler-1", %{"speed" => 41.0})
      Devices.set("acme", "filler-2", %{"speed" => 1.0})

      assert [
               %{"elementId" => "filler-1", "value" => %{"speed" => 41.0}, "quality" => "Good"},
               %{"elementId" => "filler-2", "value" => %{"speed" => 1.0}}
             ] = sync(key)

      # The guest could never register filler-2, so it hears nothing of it.
      assert [%{"elementId" => "filler-1"}] = sync(guest, actor: :guest)
    end

    test "a published value is delivered as it is" do
      key = subscribe(["filler-1"])
      Devices.set("acme", "filler-1", %{"speed" => 42.0}, with_value: true)

      assert [%{"elementId" => "filler-1", "value" => %{"speed" => 42.0, "running" => true}}] =
               sync(key)
    end

    test "a change in another tenant is not this subscriber's" do
      key = subscribe(["filler-1"])
      AshI3x.Source.publish(Devices, "other", "filler-1", %{value: 1})
      AshI3x.Source.publish(Devices, "acme", "filler-9", %{value: 1})

      assert [] = sync(key)
    end

    test "unregistering stops the updates" do
      key = subscribe(["filler-1"])
      request(:post, "/subscriptions/unregister", Map.put(key, "elementIds", ["filler-1"]))
      Devices.set("acme", "filler-1", %{"speed" => 43.0})

      assert [] = sync(key)
    end
  end

  test "sources and domains are served together" do
    opts =
      Keyword.merge(@opts,
        domains: [AshI3x.Test.Plant],
        namespace: "https://example.com/ns/plant"
      )

    line = Ash.create!(AshI3x.Test.Line, %{name: "Line A"})
    on_exit(fn -> Ash.DataLayer.Ets.stop(AshI3x.Test.Line) end)

    ids =
      request(:get, "/objects", nil, opts: opts, actor: nil)
      |> result()
      |> Enum.map(& &1["elementId"])

    assert ("line:" <> line.id) in ids
    assert "filler-1" in ids

    types =
      request(:get, "/objecttypes", nil, opts: opts, actor: nil)
      |> result()
      |> Enum.map(& &1["elementId"])

    assert "LineType" in types and "FillerType" in types

    assert [%{"success" => true}, %{"success" => true}] =
             results(
               request(
                 :post,
                 "/objects/value",
                 %{"elementIds" => ["filler-1", "line:" <> line.id]},
                 opts: opts,
                 actor: nil
               )
             )
  end
end
