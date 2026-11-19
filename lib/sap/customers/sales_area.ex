defmodule Sap.Customers.SalesArea do
  @moduledoc """
  A customer's data for one sales area (an `A_CustomerSalesArea` row).

  The sales area is the combination of `:sales_organization`, `:distribution_channel` and
  `:division`. The rest are that customer's defaults there: `:currency`,
  `:customer_payment_terms`, `:incoterms_classification`, `:incoterms_location`,
  `:shipping_condition`, `:delivery_priority`, `:supplying_plant` and
  `:customer_pricing_procedure`. `:order_block` is SAP's block reason code for the sales area.

  `:partner_functions` holds `Sap.Customers.PartnerFunction` structs, `[]` unless the request
  expanded them.
  """

  alias Sap.Customers.PartnerFunction
  alias Sap.Odata.Decode

  @type t :: %__MODULE__{
          customer: String.t() | nil,
          sales_organization: String.t() | nil,
          distribution_channel: String.t() | nil,
          division: String.t() | nil,
          currency: String.t() | nil,
          customer_payment_terms: String.t() | nil,
          incoterms_classification: String.t() | nil,
          incoterms_location: String.t() | nil,
          shipping_condition: String.t() | nil,
          delivery_priority: String.t() | nil,
          supplying_plant: String.t() | nil,
          customer_pricing_procedure: String.t() | nil,
          order_block: String.t() | nil,
          partner_functions: [PartnerFunction.t()],
          raw: map()
        }

  defstruct customer: nil,
            sales_organization: nil,
            distribution_channel: nil,
            division: nil,
            currency: nil,
            customer_payment_terms: nil,
            incoterms_classification: nil,
            incoterms_location: nil,
            shipping_condition: nil,
            delivery_priority: nil,
            supplying_plant: nil,
            customer_pricing_procedure: nil,
            order_block: nil,
            partner_functions: [],
            raw: %{}

  @doc "Decodes an `A_CustomerSalesArea` row."
  @spec from_odata(map()) :: t()
  def from_odata(row) when is_map(row) do
    %__MODULE__{
      customer: Decode.string(row["Customer"]),
      sales_organization: Decode.string(row["SalesOrganization"]),
      distribution_channel: Decode.string(row["DistributionChannel"]),
      division: Decode.string(row["Division"]),
      currency: Decode.string(row["Currency"]),
      customer_payment_terms: Decode.string(row["CustomerPaymentTerms"]),
      incoterms_classification: Decode.string(row["IncotermsClassification"]),
      incoterms_location:
        Decode.first_string(row, ["IncotermsLocation1", "IncotermsTransferLocation"]),
      shipping_condition: Decode.string(row["ShippingCondition"]),
      delivery_priority: Decode.string(row["DeliveryPriority"]),
      supplying_plant: Decode.string(row["SupplyingPlant"]),
      customer_pricing_procedure: Decode.string(row["CustomerPricingProcedure"]),
      order_block: Decode.string(row["OrderIsBlockedForCustomer"]),
      partner_functions:
        row |> Decode.nav("to_PartnerFunction") |> Enum.map(&PartnerFunction.from_odata/1),
      raw: row
    }
  end
end
