defmodule Sap.SalesOrders.Params.Partners.Create do
  @moduledoc """
  A partner of a sales order being created (`A_SalesOrderHeaderPartner`, under `to_Partner`).

  `:partner_function` is SAP's code for the role, for example `"WE"` (ship-to), `"RE"` (bill-to)
  or `"RG"` (payer). `:customer` is that partner's customer number.
  """

  alias Sap.Odata.Encode

  @type t :: %__MODULE__{partner_function: String.t(), customer: String.t()}

  @enforce_keys [:partner_function, :customer]
  defstruct [:partner_function, :customer]

  @doc "The `A_SalesOrderHeaderPartner` body for a deep insert."
  @spec to_odata(t()) :: map()
  def to_odata(%__MODULE__{} = partner) do
    Encode.compact(%{
      "PartnerFunction" => partner.partner_function,
      "Customer" => partner.customer
    })
  end
end
