defmodule AshI3x.Object do
  @moduledoc """
  An i3X Object as a source hands it to `AshI3x.Plug`.

    * `:element_id` - the elementId, unique across every source the plug serves.
    * `:type` - the elementId of its Object Type.
    * `:namespace` - the Namespace URI of that type.
    * `:display_name` - defaults to the elementId.
    * `:source_type_id` - defaults to `:type`.
    * `:description` - optional.
    * `:writable?` - whether `PUT /objects/value` may be tried on it.
    * `:history_writable?` - whether `PUT /objects/history` may be tried on it.
    * `:tenant` - what tells this Object's changes apart from another
      tenant's Object with the same elementId. Defaults to the tenant of the
      request, which is right unless the Object is shared by every tenant.
    * `:data` - anything the source wants back when it is asked about the Object.
  """

  @enforce_keys [:element_id, :type]
  defstruct [
    :element_id,
    :type,
    :namespace,
    :display_name,
    :source_type_id,
    :description,
    :data,
    :source,
    tenant: :request,
    writable?: false,
    history_writable?: false
  ]

  @type t :: %__MODULE__{
          element_id: String.t(),
          type: String.t(),
          namespace: String.t() | nil,
          display_name: String.t() | nil,
          source_type_id: String.t() | nil,
          description: String.t() | nil,
          data: term,
          source: {module, term} | nil,
          tenant: term,
          writable?: boolean,
          history_writable?: boolean
        }
end
