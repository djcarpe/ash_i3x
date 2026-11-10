defmodule AshI3x.History do
  @moduledoc """
  Where an Object's historical values come from.

  Ash has no notion of history, so `/objects/history` asks a module you name
  in the resource's `i3x` section:

      i3x do
        history MyApp.Plant.PumpHistory
      end

  A resource without one answers history queries with no values, which is
  what the specification asks of a platform that retains nothing.

  Each entry is a map with a `:value` shaped like the Object's current value,
  a `:timestamp` and optionally a `:quality` (default `"Good"`).
  """

  @type entry :: %{
          required(:value) => term,
          required(:timestamp) => DateTime.t(),
          optional(:quality) => String.t()
        }

  @typedoc "The module's own options, plus `:actor` and `:tenant` of the request."
  @type opts :: keyword

  @doc "The record's values between two instants, inclusive, in the order to return them."
  @callback read(Ash.Resource.record(), from :: DateTime.t(), to :: DateTime.t(), opts) ::
              {:ok, [entry]} | {:error, term}

  @doc """
  Creates or replaces the historical value at the entry's timestamp. Leaving
  this out makes `PUT /objects/history` answer 501 for the resource.
  """
  @callback write(Ash.Resource.record(), entry, opts) :: :ok | {:error, term}

  @optional_callbacks write: 3
end
