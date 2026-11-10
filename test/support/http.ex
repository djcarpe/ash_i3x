defmodule AshI3x.Test.Http do
  @moduledoc false

  # One request to the plug, callable on another node.

  import Plug.Conn
  import Plug.Test

  def request(method, path, body, opts, tenant, actor) do
    conn =
      if body,
        do:
          conn(method, path, Jason.encode!(body))
          |> put_req_header("content-type", "application/json"),
        else: conn(method, path)

    conn =
      conn
      |> Ash.PlugHelpers.set_tenant(tenant)
      |> Ash.PlugHelpers.set_actor(actor)
      |> AshI3x.Plug.call(AshI3x.Plug.init(opts))

    {conn.status, Jason.decode!(conn.resp_body)}
  end
end
