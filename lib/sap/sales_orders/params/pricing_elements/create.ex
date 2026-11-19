defmodule Sap.SalesOrders.Params.PricingElements.Create do
  @moduledoc """
  A pricing condition of a sales order or item being created (under `to_PricingElement`).

  `:condition_type` is SAP's condition type, for example `"PR00"`. `:condition_rate_value` is an
  integer, a `Decimal` or a decimal string; a float raises `ArgumentError`.
  `:condition_currency` is optional.
  """

  alias Sap.Odata.Encode

  @type t :: %__MODULE__{
          condition_type: String.t(),
          condition_rate_value: integer() | Decimal.t() | String.t(),
          condition_currency: String.t() | nil
        }

  @enforce_keys [:condition_type, :condition_rate_value]
  defstruct [:condition_type, :condition_rate_value, condition_currency: nil]

  @doc "The pricing element body for a deep insert."
  @spec to_odata(t()) :: map()
  def to_odata(%__MODULE__{} = element) do
    Encode.compact(%{
      "ConditionType" => element.condition_type,
      "ConditionRateValue" => Encode.number(element.condition_rate_value),
      "ConditionCurrency" => element.condition_currency
    })
  end
end
