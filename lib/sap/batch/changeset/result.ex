defmodule Sap.Batch.Changeset.Result do
  @moduledoc """
  The outcome of one `Sap.Batch.Changeset`.

  A changeset is atomic. When it commits, `:results` holds one `Sap.Batch.Result` per operation,
  in order, and `:error` is `nil`. When any operation fails SAP rolls the whole changeset back and
  answers with a single error: `:error` holds it and `:results` is empty.
  """

  alias Sap.Batch.Result
  alias Sap.Error

  @type t :: %__MODULE__{results: [Result.t()], error: Error.t() | nil}

  defstruct results: [], error: nil

  @doc "Whether the changeset committed."
  @spec ok?(t()) :: boolean()
  def ok?(%__MODULE__{error: nil, results: results}), do: Enum.all?(results, &Result.ok?/1)
  def ok?(%__MODULE__{}), do: false
end
