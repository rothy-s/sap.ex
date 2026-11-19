defmodule Sap.Batch.Changeset do
  @moduledoc """
  A group of write operations inside a `Sap.Batch` that SAP commits together or not at all.

  Reads must not go in a changeset.
  """

  alias Sap.Operation

  @type t :: %__MODULE__{operations: [Operation.t()]}

  @enforce_keys [:operations]
  defstruct [:operations]
end
