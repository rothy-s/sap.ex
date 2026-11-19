defmodule Sap.Customers.PartnerFunction do
  @moduledoc """
  One partner of a customer in a sales area (an `A_CustSalesPartnerFunc` row).

  `:partner_function` is SAP's code for the role, for example `"WE"` (ship-to), `"RE"` (bill-to)
  or `"RG"` (payer), and `:bp_customer_number` is the customer that fills it. A customer can have
  several partners in one role; `:default_partner` marks the default and `:partner_counter`
  tells them apart.
  """

  alias Sap.Odata.Decode

  @type t :: %__MODULE__{
          customer: String.t() | nil,
          sales_organization: String.t() | nil,
          distribution_channel: String.t() | nil,
          division: String.t() | nil,
          partner_counter: String.t() | nil,
          partner_function: String.t() | nil,
          bp_customer_number: String.t() | nil,
          customer_partner_description: String.t() | nil,
          default_partner: boolean() | nil,
          raw: map()
        }

  defstruct customer: nil,
            sales_organization: nil,
            distribution_channel: nil,
            division: nil,
            partner_counter: nil,
            partner_function: nil,
            bp_customer_number: nil,
            customer_partner_description: nil,
            default_partner: nil,
            raw: %{}

  @doc "Decodes an `A_CustSalesPartnerFunc` row."
  @spec from_odata(map()) :: t()
  def from_odata(row) when is_map(row) do
    %__MODULE__{
      customer: Decode.string(row["Customer"]),
      sales_organization: Decode.string(row["SalesOrganization"]),
      distribution_channel: Decode.string(row["DistributionChannel"]),
      division: Decode.string(row["Division"]),
      partner_counter: Decode.string(row["PartnerCounter"]),
      partner_function: Decode.string(row["PartnerFunction"]),
      bp_customer_number: Decode.string(row["BPCustomerNumber"]),
      customer_partner_description: Decode.string(row["CustomerPartnerDescription"]),
      default_partner: Decode.boolean(row["DefaultPartner"]),
      raw: row
    }
  end
end
