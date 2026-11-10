defmodule AshI3x.Resource.AddNotifier do
  @moduledoc false

  use Spark.Dsl.Transformer

  alias Spark.Dsl.Transformer

  @impl true
  def transform(dsl) do
    notifiers = Transformer.get_persisted(dsl, :simple_notifiers, [])

    {:ok, Transformer.persist(dsl, :simple_notifiers, Enum.uniq(notifiers ++ [AshI3x.Notifier]))}
  end
end
