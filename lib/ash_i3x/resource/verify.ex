defmodule AshI3x.Resource.Verify do
  @moduledoc false

  use Spark.Dsl.Verifier

  alias AshI3x.Resource.Info
  alias Spark.Dsl.Verifier

  @builtin ~w(HasParent HasChildren HasComponent ComponentOf)

  @impl true
  def verify(dsl) do
    module = Verifier.get_persisted(dsl, :module)

    with :ok <- verify_identifier(dsl, module),
         :ok <- verify_attributes(dsl, module),
         :ok <- verify_value(dsl, module),
         :ok <- verify_actions(dsl, module),
         :ok <- verify_hierarchy(dsl, module) do
      verify_relationships(dsl, module)
    end
  end

  defp verify_identifier(dsl, module) do
    case Info.identifier(dsl) do
      nil ->
        error(module, [:identifier], "has a composite primary key, so `identifier` must be set")

      name ->
        if Ash.Resource.Info.attribute(dsl, name),
          do: :ok,
          else: error(module, [:identifier], "#{inspect(name)} is not an attribute")
    end
  end

  defp verify_attributes(dsl, module) do
    Enum.reduce_while(~w(display_name description quality timestamp)a, :ok, fn option, :ok ->
      name = apply(Info, option, [dsl])

      if is_nil(name) or Ash.Resource.Info.attribute(dsl, name),
        do: {:cont, :ok},
        else: {:halt, error(module, [option], "#{inspect(name)} is not an attribute")}
    end)
  end

  defp verify_value(dsl, module) do
    {fields, _scalar?} = Info.value(dsl)

    Enum.reduce_while(fields, :ok, fn name, :ok ->
      case Ash.Resource.Info.field(dsl, name) do
        %struct{}
        when struct in [
               Ash.Resource.Attribute,
               Ash.Resource.Calculation,
               Ash.Resource.Aggregate
             ] ->
          {:cont, :ok}

        _ ->
          {:halt,
           error(
             module,
             [:value],
             "#{inspect(name)} is not an attribute, calculation or aggregate"
           )}
      end
    end)
  end

  defp verify_actions(dsl, module) do
    with :ok <- verify_action(dsl, module, :read_action, Info.read_action(dsl), :read) do
      case Info.update_action(dsl) do
        nil -> :ok
        name -> verify_action(dsl, module, :update_action, name, :update)
      end
    end
  end

  defp verify_action(dsl, module, option, name, type) do
    case name && Ash.Resource.Info.action(dsl, name) do
      %{type: ^type} ->
        :ok

      nil when is_nil(name) ->
        error(module, [option], "the resource has no primary #{type} action")

      nil ->
        error(module, [option], "there is no #{type} action #{inspect(name)}")

      _ ->
        error(module, [option], "#{inspect(name)} is not a #{type} action")
    end
  end

  defp verify_hierarchy(dsl, module) do
    Enum.reduce_while([:parent, :component_of], :ok, fn option, :ok ->
      name = apply(Info, option, [dsl])

      case name && Ash.Resource.Info.relationship(dsl, name) do
        nil when is_nil(name) -> {:cont, :ok}
        %{type: :belongs_to} -> {:cont, :ok}
        _ -> {:halt, error(module, [option], "#{inspect(name)} is not a belongs_to relationship")}
      end
    end)
  end

  defp verify_relationships(dsl, module) do
    Enum.reduce_while(Info.relationships(dsl), :ok, fn entity, :ok ->
      path = [:relationship, entity.relationship]

      cond do
        is_nil(Ash.Resource.Info.relationship(dsl, entity.relationship)) ->
          {:halt, error(module, path, "#{inspect(entity.relationship)} is not a relationship")}

        entity.type in @builtin or entity.reverse in @builtin ->
          {:halt,
           error(
             module,
             path,
             "#{Enum.join(@builtin, ", ")} are built in; use `parent` and `component_of` for them"
           )}

        entity.type == entity.reverse ->
          {:halt, error(module, path, "`type` and `reverse` must differ")}

        true ->
          {:cont, :ok}
      end
    end)
  end

  defp error(module, path, message) do
    {:error,
     Spark.Error.DslError.exception(module: module, path: [:i3x | path], message: message)}
  end
end
