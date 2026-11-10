defmodule AshI3x.Resource.Relationship do
  @moduledoc "A graph relationship a resource exposes over i3X."

  defstruct [:relationship, :type, :reverse, __identifier__: nil, __spark_metadata__: nil]

  @type t :: %__MODULE__{relationship: atom, type: String.t(), reverse: String.t()}

  @doc false
  def schema do
    [
      relationship: [
        type: :atom,
        required: true,
        doc: "The Ash relationship to expose. Its destination must also use `AshI3x.Resource`."
      ],
      type: [
        type: :string,
        required: true,
        doc: "The elementId of the i3X Relationship Type, e.g. `\"SuppliesTo\"`."
      ],
      reverse: [
        type: :string,
        required: true,
        doc: """
        The elementId of the reverse Relationship Type, e.g. `"SuppliedBy"`. i3X
        requires every relationship to be traversable in both directions, so the
        destination object reports this edge back without declaring anything.
        """
      ]
    ]
  end
end
