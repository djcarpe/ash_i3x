defmodule AshI3x.ClusterTest do
  use ExUnit.Case, async: false

  alias AshI3x.Test.Devices
  alias AshI3x.Test.Http

  @moduletag :cluster
  @opts [sources: [Devices]]

  setup do
    # Linked: the peer goes away with the test.
    {:ok, _peer, node} =
      :peer.start_link(%{
        name: :"ash_i3x_peer_#{System.unique_integer([:positive])}",
        host: ~c"127.0.0.1",
        longnames: true,
        args: [~c"-setcookie", Atom.to_charlist(Node.get_cookie())]
      })

    :ok = :erpc.call(node, :code, :add_paths, [:code.get_path()])
    {:ok, _} = :erpc.call(node, Application, :ensure_all_started, [:ash_i3x])

    data = Devices.sample()
    start_supervised!(%{id: Devices, start: {Devices, :start, [data]}})
    {:ok, _} = :erpc.call(node, Agent, :start, [Function, :identity, [data], [name: Devices]])

    %{node: node}
  end

  defp here(method, path, body), do: Http.request(method, path, body, @opts, "acme", nil)

  defp there(node, method, path, body),
    do: :erpc.call(node, Http, :request, [method, path, body, @opts, "acme", nil])

  defp updates({200, %{"result" => batches}}),
    do: for(%{"updates" => updates} <- batches, update <- updates, do: update["value"]["speed"])

  # Group membership reaches the other node a moment after the join.
  defp listened?(element_id) do
    Enum.any?(1..200, fn _ ->
      :pg.get_members(AshI3x.Subscription.Listeners, {Devices, "acme", element_id}) != [] or
        (Process.sleep(10) && false)
    end)
  end

  test "a subscription is served by whichever node is asked", %{node: node} do
    {200, %{"result" => %{"subscriptionId" => id}}} =
      there(node, :post, "/subscriptions", %{"clientId" => "c1"})

    key = %{"clientId" => "c1", "subscriptionId" => id}

    # Registered through this node, held on the other.
    assert {200, %{"success" => true}} =
             here(:post, "/subscriptions/register", Map.put(key, "elementIds", ["filler-1"]))

    assert {200, %{"results" => [%{"result" => %{"monitoredObjects" => [_]}}]}} =
             here(:post, "/subscriptions/list", %{"clientId" => "c1", "subscriptionIds" => [id]})

    assert {200, %{"results" => [%{"success" => false}]}} =
             here(:post, "/subscriptions/list", %{"clientId" => "c2", "subscriptionIds" => [id]})

    assert listened?("filler-1")

    # Published here, collected here from the subscription over there.
    AshI3x.Source.publish(Devices, "acme", "filler-1", %{value: %{"speed" => 1.0}})
    assert [1.0] = updates(here(:post, "/subscriptions/sync", key))

    # Published there, collected there; the first batch is still unacknowledged.
    :erpc.call(node, AshI3x.Source, :publish, [
      Devices,
      "acme",
      "filler-1",
      %{value: %{"speed" => 2.0}}
    ])

    assert [1.0, 2.0] = updates(there(node, :post, "/subscriptions/sync", key))

    assert {200, %{"success" => true}} =
             here(:post, "/subscriptions/delete", %{"clientId" => "c1", "subscriptionIds" => [id]})

    assert {404, _} = there(node, :post, "/subscriptions/sync", key)
  end

  test "a subscription here hears a change published on another node", %{node: node} do
    {200, %{"result" => %{"subscriptionId" => id}}} =
      here(:post, "/subscriptions", %{"clientId" => "c1"})

    key = %{"clientId" => "c1", "subscriptionId" => id}
    here(:post, "/subscriptions/register", Map.put(key, "elementIds", ["filler-1"]))

    assert Enum.any?(1..200, fn _ ->
             :erpc.call(node, :pg, :get_members, [
               AshI3x.Subscription.Listeners,
               {Devices, "acme", "filler-1"}
             ]) != [] or (Process.sleep(10) && false)
           end)

    :erpc.call(node, AshI3x.Source, :publish, [
      Devices,
      "acme",
      "filler-1",
      %{value: %{"speed" => 3.0}}
    ])

    assert [3.0] = updates(here(:post, "/subscriptions/sync", key))
  end

  test "a subscription nobody holds is not found on any node", %{node: node} do
    key = %{"clientId" => "c1", "subscriptionId" => "nope"}
    assert {404, _} = here(:post, "/subscriptions/sync", key)
    assert {404, _} = there(node, :post, "/subscriptions/sync", key)
  end
end
