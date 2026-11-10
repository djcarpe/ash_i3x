defmodule AshI3x.JsonSchema do
  @moduledoc false

  # JSON Schema for the Ash types an Object's value is made of. Anything not
  # recognised gets the empty schema, which permits every value.

  @strings [Ash.Type.String, Ash.Type.CiString]
  @uuids [Ash.Type.UUID, Ash.Type.UUIDv7]
  @numbers [Ash.Type.Float, Ash.Type.Decimal]
  @datetimes [
    Ash.Type.UtcDatetime,
    Ash.Type.UtcDatetimeUsec,
    Ash.Type.DateTime,
    Ash.Type.NaiveDatetime
  ]
  @objects [Ash.Type.Map, Ash.Type.Struct, Ash.Type.Keyword]

  @doc "The schema of an attribute, calculation or aggregate, nullable unless it says otherwise."
  def field(field) do
    schema = type(field.type, Map.get(field, :constraints) || [])

    if Map.get(field, :allow_nil?, true), do: nullable(schema), else: schema
  end

  @doc "The schema of the public attributes of a resource."
  def object(fields) do
    required = for field <- fields, Map.get(field, :allow_nil?, true) == false, do: name(field)

    schema = %{
      "type" => "object",
      "properties" => Map.new(fields, &{name(&1), field(&1)})
    }

    if required == [], do: schema, else: Map.put(schema, "required", required)
  end

  def type({:array, type}, constraints),
    do: %{"type" => "array", "items" => type(type, constraints[:items] || [])}

  def type(type, _) when type in @strings, do: %{"type" => "string"}
  def type(type, _) when type in @uuids, do: %{"type" => "string", "format" => "uuid"}
  def type(type, _) when type in @numbers, do: %{"type" => "number"}
  def type(type, _) when type in @datetimes, do: %{"type" => "string", "format" => "date-time"}
  def type(type, _) when type in @objects, do: %{"type" => "object"}
  def type(Ash.Type.Boolean, _), do: %{"type" => "boolean"}
  def type(Ash.Type.Date, _), do: %{"type" => "string", "format" => "date"}
  def type(Ash.Type.Time, _), do: %{"type" => "string", "format" => "time"}

  def type(Ash.Type.Integer, constraints) do
    %{"type" => "integer"}
    |> put("minimum", constraints[:min])
    |> put("maximum", constraints[:max])
  end

  def type(Ash.Type.Atom, constraints) do
    put(%{"type" => "string"}, "enum", constraints[:one_of] && strings(constraints[:one_of]))
  end

  def type(type, constraints) when is_atom(type) do
    cond do
      Ash.Type.embedded_type?(type) ->
        object(Ash.Resource.Info.public_attributes(type))

      Ash.Type.NewType.new_type?(type) ->
        type(
          Ash.Type.NewType.subtype_of(type),
          Ash.Type.NewType.constraints(type, constraints)
        )

      function_exported?(type, :values, 0) ->
        %{"type" => "string", "enum" => strings(type.values())}

      true ->
        %{}
    end
  end

  def type(_, _), do: %{}

  defp nullable(%{"type" => type} = schema) when is_binary(type),
    do: %{schema | "type" => [type, "null"]}

  defp nullable(schema), do: schema

  defp put(schema, _key, nil), do: schema
  defp put(schema, key, value), do: Map.put(schema, key, value)

  defp strings(values), do: Enum.map(values, &to_string/1)
  defp name(field), do: to_string(field.name)
end
