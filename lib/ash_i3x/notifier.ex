defmodule AshI3x.Notifier do
  @moduledoc """
  Feeds subscriptions. `AshI3x.Resource` adds this notifier to the resource.

  Subscriptions see what Ash notifies about: creates and updates that go
  through actions. Bulk actions only notify with `notify?: true`, and writes
  that bypass Ash are never seen.
  """

  use Ash.Notifier

  @impl true
  def notify(%Ash.Notifier.Notification{action: %{type: type}, data: %resource{} = record} = n)
      when type in [:create, :update] do
    tenant = n.changeset && n.changeset.tenant
    AshI3x.Subscription.publish(resource, tenant, record)
  end

  def notify(_notification), do: :ok
end
