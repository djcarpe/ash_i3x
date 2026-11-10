defmodule AshI3x.Plug do
  @moduledoc """
  Serves the i3X 1.0 API for the resources of some domains, for
  `AshI3x.Source` modules, or for both.

  The specification puts the API under `/v1`, so mount it there:

      # Phoenix
      forward "/i3x/v1", AshI3x.Plug, domains: [MyApp.Plant]

      # Plug.Router
      forward "/v1", to: AshI3x.Plug, init_opts: [domains: [MyApp.Plant]]

  ## Options

    * `:domains` - the domains whose `AshI3x.Resource` resources to serve.
    * `:sources` - `AshI3x.Source` modules, each a module or `{module, opts}`,
      for Object Types that are not resources. At least one of `:domains` and
      `:sources` is required.
    * `:namespace` - the Namespace URI of resources that do not set their own.
    * `:namespaces` - a map of Namespace URI to displayName. A Namespace
      without an entry is displayed as its URI.
    * `:server_name` and `:server_version` - reported by `GET /info`.
    * `:max_depth` - how many levels of composition one read may return.
      Reads that want more get a 206. Defaults to 10.
    * `:stream?` - whether to offer `/subscriptions/stream`. Defaults to `true`.
    * `:subscription_ttl` - milliseconds a subscription survives without a
      sync or an open stream. Defaults to five minutes.
    * `:queue_limit` - updates a subscription holds before dropping the
      oldest. Defaults to 10,000.
    * `:keepalive` - milliseconds between comments sent down an idle stream,
      which is also how a vanished client is noticed. Defaults to 15,000.

  ## Authentication and authorization

  i3X leaves the authentication scheme open, so this plug has none: put
  yours in front of it, exempting `GET /info`, which the specification says
  must stay open. Set the actor and tenant with `Ash.PlugHelpers.set_actor/2`
  and `Ash.PlugHelpers.set_tenant/2`; every read and write then runs as that
  actor with `authorize?: true`, and subscriptions deliver only what the
  actor who registered them may read.
  """

  @behaviour Plug

  import Plug.Conn

  alias AshI3x.Sources
  alias AshI3x.Subscription
  alias AshI3x.Value

  require Logger

  @parsers Plug.Parsers.init(parsers: [:json], pass: ["*/*"], json_decoder: Jason)

  @titles %{
    206 => "Partial Content",
    400 => "Bad Request",
    403 => "Forbidden",
    404 => "Not Found",
    500 => "Internal Server Error",
    501 => "Not Implemented"
  }

  @impl true
  def init(opts) do
    opts
    |> Keyword.validate!([
      :domains,
      :sources,
      :namespace,
      :namespaces,
      :server_name,
      :server_version,
      max_depth: 10,
      stream?: true,
      subscription_ttl: :timer.minutes(5),
      queue_limit: 10_000,
      keepalive: 15_000
    ])
    |> Map.new()
    |> then(fn opts ->
      case Sources.from_opts(opts) do
        [] -> raise ArgumentError, "AshI3x.Plug needs :domains or :sources"
        sources -> Map.put(opts, :sources, sources)
      end
    end)
  end

  @impl true
  def call(conn, opts) do
    case handle(conn, opts) do
      {:stream, subscription} -> stream(conn, subscription, opts)
      {status, body} -> send_json(conn, status, body)
    end
  end

  defp handle(conn, opts) do
    conn = conn |> Plug.Parsers.call(@parsers) |> fetch_query_params()

    ctx = %{
      sources: opts.sources,
      namespaces: opts[:namespaces],
      actor: Ash.PlugHelpers.get_actor(conn),
      tenant: Ash.PlugHelpers.get_tenant(conn),
      max_depth: opts.max_depth,
      subscription_ttl: opts.subscription_ttl,
      queue_limit: opts.queue_limit
    }

    params = if conn.method == "GET", do: conn.query_params, else: conn.body_params

    case route(conn.method, conn.path_info, params, ctx, opts) do
      {:error, status, detail} -> failure(status, detail)
      response -> response
    end
  rescue
    error in [Plug.Parsers.ParseError, Plug.Parsers.BadEncodingError] ->
      failure(400, Exception.message(error))

    error in [Ash.Error.Forbidden] ->
      failure(403, Exception.message(error))

    error in [Ash.Error.Invalid] ->
      failure(400, Exception.message(error))

    error ->
      Logger.error(Exception.format(:error, error, __STACKTRACE__))
      failure(500, "The request could not be served.")
  end

  ## Explore

  defp route("GET", ["info"], _params, ctx, opts) do
    success(%{
      specVersion: "1.0",
      serverName: opts[:server_name],
      serverVersion: opts[:server_version],
      capabilities: %{
        query: %{history: Sources.can?(ctx, :history)},
        update: %{
          current: Sources.can?(ctx, :write),
          history: Sources.can?(ctx, :write_history)
        },
        subscribe: %{stream: opts.stream?}
      }
    })
  end

  defp route("GET", ["namespaces"], _params, ctx, _opts), do: success(Sources.namespaces(ctx))

  defp route("GET", ["objecttypes"], params, ctx, _opts) do
    ctx
    |> Sources.object_types()
    |> in_namespace(params, & &1.namespaceUri)
    |> Enum.sort_by(& &1.elementId)
    |> success()
  end

  defp route("POST", ["objecttypes", "query"], params, ctx, _opts) do
    with {:ok, ids} <- strings(params, "elementIds") do
      types = ctx |> Sources.object_types() |> Map.new(&{&1.elementId, &1})

      bulk(ids, :elementId, fn id ->
        case types do
          %{^id => type} -> {:ok, type}
          _ -> {:error, 404, "Object type not found: #{id}"}
        end
      end)
    end
  end

  defp route("GET", ["relationshiptypes"], params, ctx, _opts),
    do:
      ctx |> Sources.relationship_types() |> in_namespace(params, & &1.namespaceUri) |> success()

  defp route("POST", ["relationshiptypes", "query"], params, ctx, _opts) do
    with {:ok, ids} <- strings(params, "elementIds") do
      types = Sources.relationship_types(ctx)

      bulk(ids, :elementId, fn id ->
        case Enum.find(types, &(&1.elementId == id)) do
          nil -> {:error, 404, "Relationship type not found: #{id}"}
          type -> {:ok, type}
        end
      end)
    end
  end

  defp route("GET", ["objects"], params, ctx, _opts) do
    ctx
    |> Sources.list(params["typeElementId"], params["root"] == "true")
    |> Sources.describe(ctx, params["includeMetadata"] == "true")
    |> Enum.sort_by(& &1.elementId)
    |> success()
  end

  defp route("POST", ["objects", "list"], params, ctx, _opts) do
    with {:ok, ids} <- strings(params, "elementIds") do
      found = Sources.fetch(ids, ctx)
      objects = Map.values(found)

      described =
        objects
        |> Sources.describe(ctx, params["includeMetadata"] == true)
        |> Map.new(&{&1.elementId, &1})

      objects(ids, described, &{:ok, &1})
    end
  end

  defp route("POST", ["objects", "related"], params, ctx, _opts) do
    with {:ok, ids} <- strings(params, "elementIds"),
         {:ok, type} <- optional_string(params, "relationshipType") do
      found = Sources.fetch(ids, ctx)
      edges = Sources.edges(Map.values(found), ctx, if(type, do: [type], else: :all))

      described =
        for({_id, edges} <- edges, {_type, object} <- edges, do: object)
        |> Enum.uniq_by(& &1.element_id)
        |> Sources.describe(ctx, params["includeMetadata"] == true)
        |> Map.new(&{&1.elementId, &1})

      objects(ids, found, fn object ->
        {:ok,
         for {type, target} <- Map.get(edges, object.element_id, []) do
           %{sourceRelationship: type, object: described[target.element_id]}
         end}
      end)
    end
  end

  ## Query

  defp route("POST", ["objects", "value"], params, ctx, _opts) do
    with {:ok, ids} <- strings(params, "elementIds"),
         {:ok, max_depth} <- max_depth(params) do
      {values, partial?} =
        ids |> Sources.fetch(ctx) |> Map.values() |> Sources.values(max_depth, ctx)

      ids |> objects(values, &{:ok, &1}) |> depth_limited(partial?)
    end
  end

  defp route("POST", ["objects", "history"], params, ctx, _opts) do
    with {:ok, ids} <- strings(params, "elementIds"),
         {:ok, from} <- time(params, "startTime"),
         {:ok, to} <- time(params, "endTime"),
         {:ok, _max_depth} <- max_depth(params) do
      found = Sources.fetch(ids, ctx)
      compositions = found |> Map.values() |> Sources.compositions(ctx)

      objects(ids, found, fn object ->
        case Sources.history(object, from, to, ctx) do
          {:ok, values} ->
            {:ok, %{isComposition: object.element_id in compositions, values: values}}

          {:error, error} ->
            error(error)
        end
      end)
    end
  end

  ## Update

  defp route("PUT", ["objects", "value"], params, ctx, _opts) do
    with :ok <- supported(ctx, :write, "Writing values is not supported."),
         {:ok, updates} <- updates(params, false) do
      found = Sources.fetch(Enum.map(updates, & &1.id), ctx)

      bulk(updates, :elementId, & &1.id, fn update ->
        case found[update.id] do
          nil ->
            {:error, 404, "Element not found: #{update.id}"}

          %{writable?: false} ->
            {:error, 501, "Element cannot be written: #{update.id}"}

          object ->
            case Sources.write(object, update.value, update.quality, update.timestamp, ctx) do
              :ok -> {:ok, nil}
              {:error, error} -> error(error)
            end
        end
      end)
    end
  end

  defp route("PUT", ["objects", "history"], params, ctx, _opts) do
    with :ok <- supported(ctx, :write_history, "Writing history is not supported."),
         {:ok, updates} <- updates(params, true) do
      found = Sources.fetch(Enum.map(updates, & &1.id), ctx)

      bulk(updates, :elementId, & &1.id, fn update ->
        case found[update.id] do
          nil ->
            {:error, 404, "Element not found: #{update.id}"}

          object ->
            entry = Map.take(update, [:value, :quality, :timestamp])

            with true <- object.history_writable?,
                 :ok <- Sources.write_history(object, entry, ctx) do
              {:ok, nil}
            else
              false -> {:error, 501, "Element history cannot be written: #{update.id}"}
              {:error, error} -> error(error)
            end
        end
      end)
    end
  end

  ## Subscribe

  defp route("POST", ["subscriptions"], params, ctx, _opts) do
    with {:ok, client_id} <- string(params, "clientId"),
         {:ok, display_name} <- optional_string(params, "displayName") do
      id = Subscription.create(client_id, display_name, ctx)
      success(%{clientId: client_id, subscriptionId: id, displayName: display_name})
    end
  end

  defp route("POST", ["subscriptions", "list"], params, _ctx, _opts) do
    with_subscriptions(params, fn pid ->
      with %{} = info <- Subscription.info(pid), do: {:ok, info}
    end)
  end

  defp route("POST", ["subscriptions", "delete"], params, _ctx, _opts) do
    with_subscriptions(params, fn pid ->
      with :ok <- Subscription.delete(pid), do: {:ok, nil}
    end)
  end

  defp route("POST", ["subscriptions", "register"], params, ctx, _opts) do
    with {:ok, pid} <- subscription(params),
         {:ok, ids} <- strings(params, "elementIds"),
         {:ok, max_depth} <- max_depth(params) do
      found = Sources.fetch(ids, ctx)

      with :ok <- Subscription.register(pid, Map.values(found), max_depth),
           do: objects(ids, found, fn _object -> {:ok, nil} end)
    end
    |> gone()
  end

  defp route("POST", ["subscriptions", "unregister"], params, _ctx, _opts) do
    with {:ok, pid} <- subscription(params),
         {:ok, ids} <- strings(params, "elementIds"),
         removed when is_list(removed) <- Subscription.unregister(pid, ids) do
      bulk(ids, :elementId, fn id ->
        if id in removed, do: {:ok, nil}, else: {:error, 404, "Element not registered: #{id}"}
      end)
    end
    |> gone()
  end

  defp route("POST", ["subscriptions", "sync"], params, _ctx, opts) do
    with {:ok, pid} <- subscription(params),
         {:ok, batches, dropped?} <- Subscription.sync(pid, params["lastSequenceNumber"]) do
      if dropped? do
        detail =
          "Updates were dropped from the subscription queue. The server limit is #{opts.queue_limit} updates."

        {206,
         %{
           success: true,
           result: batches,
           responseDetail: detail(206, detail, "Updates dropped due to queue overflow")
         }}
      else
        success(batches)
      end
    else
      {:error, :streaming} ->
        {:error, 400, "The subscription has an open stream. Close it before calling sync."}

      other ->
        gone(other)
    end
  end

  defp route("POST", ["subscriptions", "stream"], params, _ctx, opts) do
    with {:ok, pid} <- subscription(params) do
      if opts.stream?, do: {:stream, pid}, else: {:error, 501, "Streaming is not supported."}
    end
  end

  defp route(_method, _path, _params, _ctx, _opts), do: {:error, 404, "No such endpoint."}

  ## Streaming

  defp stream(conn, subscription, opts) do
    case Subscription.attach(subscription, self()) do
      {:ok, ref} ->
        conn
        |> put_resp_content_type("text/event-stream")
        |> put_resp_header("cache-control", "no-cache")
        |> send_chunked(200)
        |> stream_loop(Process.monitor(subscription), ref, opts.keepalive)

      {:error, :not_found} ->
        {status, body} = failure(404, "Subscription not found.")
        send_json(conn, status, body)
    end
  end

  # Runs until the client goes away, the subscription does, or another
  # stream takes this one's place.
  defp stream_loop(conn, monitor, ref, keepalive) do
    receive do
      {:i3x_updates, ^ref, updates} ->
        stream_chunk(
          conn,
          ["data: ", Jason.encode_to_iodata!(updates), "\n\n"],
          monitor,
          ref,
          keepalive
        )

      {:i3x_closed, ^ref} ->
        conn

      {:DOWN, ^monitor, :process, _pid, _reason} ->
        conn
    after
      keepalive -> stream_chunk(conn, ": keepalive\n\n", monitor, ref, keepalive)
    end
  end

  defp stream_chunk(conn, data, monitor, ref, keepalive) do
    case chunk(conn, data) do
      {:ok, conn} -> stream_loop(conn, monitor, ref, keepalive)
      {:error, _closed} -> conn
    end
  end

  ## Requests

  defp strings(params, name) do
    case params[name] do
      list when is_list(list) ->
        if Enum.all?(list, &is_binary/1),
          do: {:ok, list},
          else: {:error, 400, "#{name} must be an array of strings."}

      _ ->
        {:error, 400, "#{name} is required and must be an array of strings."}
    end
  end

  defp string(params, name) do
    case params[name] do
      value when is_binary(value) and value != "" -> {:ok, value}
      _ -> {:error, 400, "#{name} is required."}
    end
  end

  defp optional_string(params, name) do
    case params[name] do
      value when is_binary(value) or is_nil(value) -> {:ok, value}
      _ -> {:error, 400, "#{name} must be a string."}
    end
  end

  defp max_depth(params) do
    case params["maxDepth"] do
      nil -> {:ok, 1}
      depth when is_integer(depth) and depth >= 0 -> {:ok, depth}
      _ -> {:error, 400, "maxDepth must be a non-negative integer."}
    end
  end

  defp time(params, name) do
    with value when is_binary(value) <- params[name],
         {:ok, time, _offset} <- DateTime.from_iso8601(value) do
      {:ok, time}
    else
      _ -> {:error, 400, "#{name} is required and must be an RFC 3339 timestamp."}
    end
  end

  # History needs a complete VQT; a current value only needs the value.
  defp updates(params, complete?) do
    with list when is_list(list) <- params["updates"],
         updates when is_list(updates) <- Enum.reduce_while(list, [], &update(&1, &2, complete?)) do
      {:ok, Enum.reverse(updates)}
    else
      {:error, _status, _detail} = error -> error
      _ -> {:error, 400, "updates is required and must be an array."}
    end
  end

  defp update(%{"elementId" => id, "value" => %{"value" => value} = vqt}, updates, complete?)
       when is_binary(id) do
    quality = vqt["quality"]

    timestamp =
      case vqt["timestamp"] do
        nil -> nil
        timestamp when is_binary(timestamp) -> DateTime.from_iso8601(timestamp)
        _ -> :error
      end

    cond do
      not (is_nil(quality) or Value.quality?(quality)) ->
        {:halt, {:error, 400, "quality must be Good, GoodNoData, Bad or Uncertain."}}

      not (is_nil(timestamp) or match?({:ok, _, _}, timestamp)) ->
        {:halt, {:error, 400, "timestamp must be an RFC 3339 timestamp."}}

      complete? and (is_nil(quality) or is_nil(timestamp)) ->
        {:halt, {:error, 400, "Each historical value needs a quality and a timestamp."}}

      true ->
        timestamp = with {:ok, timestamp, _offset} <- timestamp, do: timestamp
        {:cont, [%{id: id, value: value, quality: quality, timestamp: timestamp} | updates]}
    end
  end

  defp update(_update, _updates, _complete?),
    do: {:halt, {:error, 400, "Each update needs an elementId and a value holding a value."}}

  defp subscription(params) do
    with {:ok, client_id} <- string(params, "clientId"),
         {:ok, id} <- string(params, "subscriptionId") do
      case Subscription.lookup(id, client_id) do
        nil -> {:error, 404, "Subscription not found: #{id}"}
        pid -> {:ok, pid}
      end
    end
  end

  defp with_subscriptions(params, fun) do
    with {:ok, client_id} <- string(params, "clientId"),
         {:ok, ids} <- strings(params, "subscriptionIds") do
      bulk(ids, :subscriptionId, fn id ->
        with pid when is_pid(pid) <- Subscription.lookup(id, client_id),
             {:ok, result} <- fun.(pid) do
          {:ok, result}
        else
          _ -> {:error, 404, "Subscription not found: #{id}"}
        end
      end)
    end
  end

  # A subscription can expire between being found and being called.
  defp gone({:error, :not_found}), do: {:error, 404, "Subscription not found."}
  defp gone(response), do: response

  defp supported(ctx, what, message) do
    if Sources.can?(ctx, what), do: :ok, else: {:error, 501, message}
  end

  defp in_namespace(items, params, fun) do
    case params["namespaceUri"] do
      nil -> items
      uri -> Enum.filter(items, &(fun.(&1) == uri))
    end
  end

  ## Responses

  defp success(result), do: {200, %{success: true, result: result}}

  defp failure(status, detail),
    do: {status, %{success: false, responseDetail: detail(status, detail)}}

  defp detail(status, detail, title \\ nil),
    do: %{title: title || Map.fetch!(@titles, status), status: status, detail: detail}

  # One result per requested elementId, in order, from a map of what was found.
  defp objects(ids, found, fun) do
    bulk(ids, :elementId, fn id ->
      case found do
        %{^id => object} -> fun.(object)
        _ -> {:error, 404, "Element not found: #{id}"}
      end
    end)
  end

  defp bulk(items, key, id \\ & &1, fun) do
    results =
      Enum.map(items, fn item ->
        case fun.(item) do
          {:ok, result} ->
            %{:success => true, key => id.(item), :result => result}

          {:error, status, detail} ->
            %{:success => false, key => id.(item), :responseDetail => detail(status, detail)}
        end
      end)

    {200, %{success: Enum.all?(results, & &1.success), results: results}}
  end

  defp depth_limited({200, body}, true) do
    detail = "Result set was truncated due to server-imposed depth limits."
    {206, Map.put(body, :responseDetail, detail(206, detail, "Partial results returned"))}
  end

  defp depth_limited(response, false), do: response

  defp error(%Ash.Error.Forbidden{} = error), do: {:error, 403, Exception.message(error)}
  defp error(%Ash.Error.Invalid{} = error), do: {:error, 400, Exception.message(error)}
  defp error({:invalid, message}), do: {:error, 400, message}
  defp error({:forbidden, message}), do: {:error, 403, message}
  defp error({:unsupported, message}), do: {:error, 501, message}
  defp error(error) when is_exception(error), do: {:error, 500, Exception.message(error)}
  defp error(error), do: {:error, 500, inspect(error)}

  defp send_json(conn, status, body) do
    body = Jason.encode_to_iodata!(body)
    conn = put_resp_content_type(conn, "application/json")

    if gzip?(conn) do
      conn |> put_resp_header("content-encoding", "gzip") |> send_resp(status, :zlib.gzip(body))
    else
      send_resp(conn, status, body)
    end
  end

  defp gzip?(conn) do
    conn
    |> get_req_header("accept-encoding")
    |> Enum.any?(&String.contains?(&1, "gzip"))
  end
end
