defmodule Sap.Customers.Params.List do
  @moduledoc """
  Params for `Sap.Customers.list/1`: the customer numbers to look up.

  `:expand` works as in `Sap.Customers.Params.Get`. Expanding multiplies the payload by the number
  of customers, so keep the list short when you use it.
  """

  alias Sap.Customers.Params.Get

  @type t :: %__MODULE__{customers: [String.t()], expand: [Get.expansion()]}

  @enforce_keys [:customers]
  defstruct [:customers, expand: []]

  defimpl Sap.Odata.Filterable do
    alias Sap.Odata.Query

    def to_filter(params), do: Query.match(Query.new(), "Customer", params.customers)
  end
end
