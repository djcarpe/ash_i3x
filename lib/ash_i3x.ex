defmodule AshI3x do
  @moduledoc """
  Serves Ash resources over [i3X](https://i3x.dev), CESMII's common API for
  industrial information.

  A resource that uses `AshI3x.Resource` becomes an i3X Object Type, its
  records become Objects, and `AshI3x.Plug` serves them: browsing, current
  and historical values, writes and subscriptions.
  """

  @doc "The i3X elementId of a record of a resource that uses `AshI3x.Resource`."
  @spec element_id(Ash.Resource.record()) :: String.t()
  defdelegate element_id(record), to: AshI3x.Resource.Info
end
