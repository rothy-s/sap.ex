defmodule Sap.SalesOrders.Params.Get do
  @moduledoc """
  Params for `Sap.SalesOrders.get/1`: one order, by number.

  `:expand_items` defaults to `true`, so the order comes back with its items.
  """

  @type t :: %__MODULE__{sales_order: String.t(), expand_items: boolean()}

  @enforce_keys [:sales_order]
  defstruct [:sales_order, expand_items: true]
end
