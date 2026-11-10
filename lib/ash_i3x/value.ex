defmodule AshI3x.Value do
  @moduledoc false

  # Values as i3X carries them: a value, a quality and a timestamp (VQT).

  alias AshI3x.Catalog.Exposure

  @qualities ~w(Good GoodNoData Bad Uncertain)

  @doc "The current VQT of a record."
  def vqt(%Exposure{} = exposure, record) do
    value = value(exposure, record)

    %{
      value: value,
      quality: quality(exposure.quality && Map.get(record, exposure.quality), value),
      timestamp: timestamp(exposure.timestamp && Map.get(record, exposure.timestamp))
    }
  end

  @doc "A VQT from a value, quality and timestamp that came from outside."
  def vqt(value, quality, timestamp) do
    value = dump(value)
    %{value: value, quality: quality(quality, value), timestamp: timestamp(timestamp)}
  end

  defp value(%{scalar?: true, fields: [field]}, record), do: record |> Map.get(field) |> dump()

  defp value(%{fields: fields}, record) do
    value = Map.new(fields, &{to_string(&1), record |> Map.get(&1) |> dump()})

    # An Object none of whose fields has ever been set has no value yet.
    if Enum.all?(value, fn {_field, v} -> is_nil(v) end), do: nil, else: value
  end

  @doc "Normalizes a quality, keeping it consistent with whether there is a value."
  def quality(quality, value) do
    case {normalize(quality), value} do
      {quality, nil} when quality in ["Bad", "GoodNoData"] -> quality
      {_, nil} -> "GoodNoData"
      {nil, _} -> "Good"
      {"GoodNoData", _} -> "Good"
      {quality, _} -> quality
    end
  end

  @doc "Whether a string names a quality."
  def quality?(quality), do: quality in @qualities

  defp normalize(nil), do: nil
  defp normalize(quality) when quality in @qualities, do: quality

  defp normalize(quality) when is_atom(quality) or is_binary(quality) do
    camelized = quality |> to_string() |> Macro.camelize()
    if camelized in @qualities, do: camelized
  end

  defp normalize(_), do: nil

  @doc "An RFC 3339 UTC timestamp. Without a time, now."
  def timestamp(nil), do: timestamp(DateTime.utc_now())

  def timestamp(%NaiveDateTime{} = naive),
    do: naive |> DateTime.from_naive!("Etc/UTC") |> timestamp()

  def timestamp(%DateTime{} = datetime),
    do: datetime |> DateTime.shift_zone!("Etc/UTC") |> DateTime.to_iso8601()

  def timestamp(other), do: other |> dump() |> to_string()

  @doc "A term as plain JSON data."
  def dump(nil), do: nil
  def dump(value) when is_boolean(value) or is_number(value) or is_binary(value), do: value
  def dump(value) when is_atom(value), do: Atom.to_string(value)
  def dump(value) when is_list(value), do: Enum.map(value, &dump/1)
  def dump(%Decimal{} = value), do: Decimal.to_float(value)
  def dump(%Ash.CiString{} = value), do: to_string(value)
  def dump(%Ash.Union{value: value}), do: dump(value)
  def dump(%Ash.NotLoaded{}), do: nil
  def dump(%Ash.ForbiddenField{}), do: nil
  def dump(%DateTime{} = value), do: timestamp(value)

  def dump(%struct{} = value) when struct in [Date, Time, NaiveDateTime],
    do: struct.to_iso8601(value)

  def dump(%struct{} = value) do
    if Ash.Resource.Info.resource?(struct) do
      Map.new(
        Ash.Resource.Info.public_attributes(struct),
        &{to_string(&1.name), value |> Map.get(&1.name) |> dump()}
      )
    else
      value |> Map.from_struct() |> dump()
    end
  end

  def dump(value) when is_map(value), do: Map.new(value, fn {k, v} -> {to_string(k), dump(v)} end)
  def dump(value) when is_tuple(value), do: value |> Tuple.to_list() |> dump()
  def dump(value), do: inspect(value)
end
