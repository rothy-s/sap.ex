defmodule Sap.Error.Detail do
  @moduledoc """
  One entry from the `errordetails` list of a SAP OData error body.

  SAP often reports the actionable business message here, next to a generic top-level message.
  """

  @type t :: %__MODULE__{
          code: String.t() | nil,
          message: String.t() | nil,
          severity: String.t() | nil,
          target: String.t() | nil
        }

  defstruct [:code, :message, :severity, :target]

  @doc "Builds a detail from one `errordetails` row. Anything that is not a map is dropped."
  @spec from_odata(term()) :: t() | nil
  def from_odata(%{} = row) do
    %__MODULE__{
      code: text(row["code"]),
      message: text(row["message"]),
      severity: text(row["severity"]),
      target: text(row["target"])
    }
  end

  def from_odata(_other), do: nil

  defp text(value) when is_binary(value) and value != "", do: value
  defp text(_value), do: nil
end
