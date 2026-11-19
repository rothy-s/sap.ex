defmodule Sap.Customers.Params.Get do
  @moduledoc """
  Params for `Sap.Customers.get/1`: one customer, by number.

  `:expand` chooses what to load with it:

    * `:sales_areas` - the customer's `Sap.Customers.SalesArea` rows
    * `:partner_functions` - the sales areas together with each one's
      `Sap.Customers.PartnerFunction` rows
  """

  @type expansion :: :sales_areas | :partner_functions
  @type t :: %__MODULE__{customer: String.t(), expand: [expansion()]}

  @enforce_keys [:customer]
  defstruct [:customer, expand: []]
end
