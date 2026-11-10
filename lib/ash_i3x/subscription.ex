defmodule AshI3x.Subscription do
  @moduledoc """
  A client's subscription: the Objects it monitors and the updates queued
  for it.

  Each subscription is a process on the node that created it. It is fed by
  `AshI3x.Notifier`, holds updates until the client collects them with
  `/subscriptions/sync` or `/subscriptions/stream`, and stops itself when the
  client has done neither for the time to live.

  Subscriptions live in memory on one node: they do not survive a restart,
  and a client must keep talking to the node that holds its subscription.
  """

  use GenServer, restart: :temporary

  alias AshI3x.Objects
  alias AshI3x.Resource.Info
  alias AshI3x.Value

  require Logger

  @registry __MODULE__.Registry
  @listeners __MODULE__.Listeners

  @doc false
  def start_link(opts) do
    name = {:via, Registry, {@registry, opts[:id], opts[:client_id]}}
    GenServer.start_link(__MODULE__, opts, name: name)
  end

  @doc false
  def create(client_id, display_name, ctx) do
    id = 32 |> :crypto.strong_rand_bytes() |> Base.url_encode64(padding: false)
    opts = [id: id, client_id: client_id, display_name: display_name, ctx: ctx]

    {:ok, _pid} = DynamicSupervisor.start_child(__MODULE__.Supervisor, {__MODULE__, opts})
    id
  end

  @doc false
  # A subscription owned by another client is indistinguishable from none.
  def lookup(id, client_id) do
    case Registry.lookup(@registry, id) do
      [{pid, ^client_id}] -> pid
      _ -> nil
    end
  end

  @doc false
  def info(pid), do: call(pid, :info)
  @doc false
  def register(pid, objects, max_depth), do: call(pid, {:register, objects, max_depth})
  @doc false
  def unregister(pid, element_ids), do: call(pid, {:unregister, element_ids})
  @doc false
  def sync(pid, last_sequence_number), do: call(pid, {:sync, last_sequence_number})
  @doc false
  def attach(pid, stream), do: call(pid, {:attach, stream})
  @doc false
  def delete(pid), do: call(pid, :delete)

  defp call(pid, message) do
    GenServer.call(pid, message)
  catch
    :exit, _ -> {:error, :not_found}
  end

  @doc """
  Hands a changed record to the subscriptions monitoring it. `AshI3x.Notifier`
  does this for changes made through Ash actions; call it yourself for
  changes made some other way.
  """
  @spec publish(Ash.Resource.t(), tenant :: term, Ash.Resource.record()) :: :ok
  def publish(resource, tenant, record) do
    Registry.dispatch(@listeners, key(resource, tenant, Info.element_id(record)), fn entries ->
      for {pid, _} <- entries, do: send(pid, {:changed, resource, record})
    end)
  end

  # A tenant only tells Objects apart when their resource is multitenant.
  defp key(resource, tenant, element_id) do
    case Ash.Resource.Info.multitenancy_strategy(resource) do
      nil -> {nil, element_id}
      _ -> {tenant, element_id}
    end
  end

  @impl true
  def init(opts) do
    state = %{
      id: opts[:id],
      display_name: opts[:display_name],
      ctx: opts[:ctx],
      # elementId => {resource, maxDepth}
      monitored: %{},
      # Updates not yet handed out, oldest first.
      pending: :queue.new(),
      # Updates handed out by a sync and not yet acknowledged, oldest first.
      batches: [],
      queued: 0,
      next_sequence_number: 1,
      dropped?: false,
      stream: nil,
      timer: nil
    }

    {:ok, restart_timer(state)}
  end

  @impl true
  def handle_call(:info, _from, state) do
    monitored =
      for {element_id, {_resource, max_depth}} <- Enum.sort(state.monitored),
          do: %{elementId: element_id, maxDepth: max_depth}

    {:reply,
     %{subscriptionId: state.id, displayName: state.display_name, monitoredObjects: monitored},
     state}
  end

  def handle_call({:register, objects, max_depth}, _from, state) do
    monitored =
      Enum.reduce(objects, state.monitored, fn {element_id, resource}, monitored ->
        if not is_map_key(monitored, element_id),
          do: Registry.register(@listeners, key(resource, state.ctx.tenant, element_id), nil)

        Map.put_new(monitored, element_id, {resource, max_depth})
      end)

    {:reply, :ok, %{state | monitored: monitored}}
  end

  def handle_call({:unregister, element_ids}, _from, state) do
    {found, monitored} = Map.split(state.monitored, element_ids)

    for {element_id, {resource, _max_depth}} <- found,
        do: Registry.unregister(@listeners, key(resource, state.ctx.tenant, element_id))

    {:reply, Map.keys(found), %{state | monitored: monitored}}
  end

  def handle_call({:sync, _last}, _from, %{stream: {_pid, _ref}} = state),
    do: {:reply, {:error, :streaming}, state}

  def handle_call({:sync, last}, _from, state) do
    state = state |> acknowledge(last) |> batch()

    batches =
      for {number, updates} <- state.batches, do: %{sequenceNumber: number, updates: updates}

    {:reply, {:ok, batches, state.dropped?}, restart_timer(%{state | dropped?: false})}
  end

  def handle_call({:attach, pid}, _from, state) do
    state = close_stream(state)
    ref = Process.monitor(pid)
    queued = Enum.flat_map(state.batches, &elem(&1, 1)) ++ :queue.to_list(state.pending)
    if queued != [], do: send(pid, {:i3x_updates, ref, queued})

    state = cancel_timer(state)

    {:reply, {:ok, ref},
     %{state | stream: {pid, ref}, pending: :queue.new(), batches: [], queued: 0}}
  end

  def handle_call(:delete, _from, state), do: {:stop, :normal, :ok, close_stream(state)}

  @impl true
  def handle_info({:changed, resource, record}, state) do
    case update(resource, record, state) do
      nil -> {:noreply, state}
      update -> {:noreply, deliver(state, update)}
    end
  end

  def handle_info({:DOWN, ref, :process, _pid, _reason}, %{stream: {_, ref}} = state),
    do: {:noreply, restart_timer(%{state | stream: nil})}

  def handle_info({:expired, token}, %{timer: {_timer, token}} = state),
    do: {:stop, :normal, state}

  def handle_info(_message, state), do: {:noreply, state}

  # What the subscriber is told about a change. When the resource has
  # policies or loaded fields the record is read again as the subscriber; a
  # change they may no longer see is not delivered.
  defp update(resource, record, state) do
    exposure = state.ctx.catalog.exposures[resource]
    element_id = Info.element_id(record)

    current =
      cond do
        is_nil(exposure) -> nil
        exposure.reread? -> [element_id] |> Objects.fetch(state.ctx) |> Map.get(element_id)
        true -> {exposure, record}
      end

    case current do
      {exposure, record} -> exposure |> Value.vqt(record) |> Map.put(:elementId, element_id)
      nil -> nil
    end
  rescue
    error ->
      Logger.warning("i3X subscription could not read a change: " <> Exception.message(error))
      nil
  end

  defp deliver(%{stream: {pid, ref}} = state, update) do
    send(pid, {:i3x_updates, ref, [update]})
    state
  end

  defp deliver(state, update) do
    trim(%{state | pending: :queue.in(update, state.pending), queued: state.queued + 1})
  end

  # Past the limit the oldest updates go first, and the next sync says so.
  defp trim(%{queued: queued, ctx: %{queue_limit: limit}} = state) when queued > limit do
    state =
      case state.batches do
        [{_number, [_only]} | batches] -> %{state | batches: batches}
        [{number, [_ | updates]} | batches] -> %{state | batches: [{number, updates} | batches]}
        [] -> %{state | pending: :queue.drop(state.pending)}
      end

    trim(%{state | queued: queued - 1, dropped?: true})
  end

  defp trim(state), do: state

  defp acknowledge(state, -1),
    do: %{state | batches: [], pending: :queue.new(), queued: 0}

  defp acknowledge(state, last) when is_integer(last) and last >= 0 do
    batches = Enum.reject(state.batches, fn {number, _updates} -> number <= last end)
    acknowledged = Enum.sum(for {_, updates} <- state.batches -- batches, do: length(updates))

    %{state | batches: batches, queued: state.queued - acknowledged}
  end

  defp acknowledge(state, _omitted_or_invalid), do: state

  defp batch(state) do
    case :queue.to_list(state.pending) do
      [] ->
        state

      updates ->
        %{
          state
          | batches: state.batches ++ [{state.next_sequence_number, updates}],
            pending: :queue.new(),
            next_sequence_number: state.next_sequence_number + 1
        }
    end
  end

  defp close_stream(%{stream: {pid, ref}} = state) do
    Process.demonitor(ref, [:flush])
    send(pid, {:i3x_closed, ref})
    %{state | stream: nil}
  end

  defp close_stream(state), do: state

  defp restart_timer(state) do
    token = make_ref()
    timer = Process.send_after(self(), {:expired, token}, state.ctx.subscription_ttl)
    %{cancel_timer(state) | timer: {timer, token}}
  end

  defp cancel_timer(%{timer: {timer, _token}} = state) do
    Process.cancel_timer(timer)
    %{state | timer: nil}
  end

  defp cancel_timer(state), do: state
end
