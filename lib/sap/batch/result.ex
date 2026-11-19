defmodule Sap.Batch.Result do
  @moduledoc """
  The outcome of one operation inside a `Sap.Batch`.

  On a 2xx status `:data` holds the value the operation's decoder produced, exactly as a direct
  request would have returned it, and `:error` is `nil`. Otherwise `:error` holds a `Sap.Error`
  and `:data` is `nil`.
  """

  alias Sap.Error

  @type t :: %__MODULE__{
          status: non_neg_integer(),
          headers: %{optional(String.t()) => String.t()},
          data: term(),
          error: Error.t() | nil
        }

  @enforce_keys [:status]
  defstruct [:status, :data, :error, headers: %{}]

  @doc "Whether the operation succeeded."
  @spec ok?(t()) :: boolean()
  def ok?(%__MODULE__{error: nil}), do: true
  def ok?(%__MODULE__{}), do: false
end
