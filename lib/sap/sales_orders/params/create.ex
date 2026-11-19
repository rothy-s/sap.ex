defmodule Sap.SalesOrders.Params.Create do
  @moduledoc """
  Params for `Sap.SalesOrders.create/1`: a sales order header with everything created under it.

  ## Required

    * `:sales_order_type` - for example `"OR"`
    * `:sales_organization`, `:distribution_channel`, `:organization_division` - the sales area
    * `:sold_to_party` - the customer number
    * `:items` - at least one `Sap.SalesOrders.Params.Items.Create`

  ## Optional

    * `:purchase_order_by_customer` - the customer's own reference. Set it: it is how you find
      the order again when a create's outcome is unknown.
    * `:requested_delivery_date`, `:start_ship_date`, `:end_ship_date` - `Date`s
    * `:transaction_currency`, `:customer_payment_terms`, `:incoterms_classification`
    * `:partners` - `Sap.SalesOrders.Params.Partners.Create` structs, for example a ship-to that
      differs from the sold-to
    * `:pricing_elements` - header-level `Sap.SalesOrders.Params.PricingElements.Create` structs
    * `:texts` - header-level `Sap.SalesOrders.Params.Texts.Create` structs

  A field left `nil`, and a list left empty, is not sent, so SAP applies its own default.
  """

  alias Sap.Odata.Encode
  alias Sap.SalesOrders.Params.Items
  alias Sap.SalesOrders.Params.Partners
  alias Sap.SalesOrders.Params.PricingElements
  alias Sap.SalesOrders.Params.Texts

  @type t :: %__MODULE__{
          sales_order_type: String.t(),
          sales_organization: String.t(),
          distribution_channel: String.t(),
          organization_division: String.t(),
          sold_to_party: String.t(),
          purchase_order_by_customer: String.t() | nil,
          requested_delivery_date: Date.t() | nil,
          start_ship_date: Date.t() | nil,
          end_ship_date: Date.t() | nil,
          transaction_currency: String.t() | nil,
          customer_payment_terms: String.t() | nil,
          incoterms_classification: String.t() | nil,
          items: [Items.Create.t()],
          partners: [Partners.Create.t()],
          pricing_elements: [PricingElements.Create.t()],
          texts: [Texts.Create.t()]
        }

  @enforce_keys [
    :sales_order_type,
    :sales_organization,
    :distribution_channel,
    :organization_division,
    :sold_to_party
  ]
  defstruct [
    :sales_order_type,
    :sales_organization,
    :distribution_channel,
    :organization_division,
    :sold_to_party,
    purchase_order_by_customer: nil,
    requested_delivery_date: nil,
    start_ship_date: nil,
    end_ship_date: nil,
    transaction_currency: nil,
    customer_payment_terms: nil,
    incoterms_classification: nil,
    items: [],
    partners: [],
    pricing_elements: [],
    texts: []
  ]

  @doc "The `A_SalesOrder` deep-insert body."
  @spec to_odata(t()) :: map()
  def to_odata(%__MODULE__{} = order) do
    %{
      "SalesOrderType" => order.sales_order_type,
      "SalesOrganization" => order.sales_organization,
      "DistributionChannel" => order.distribution_channel,
      "OrganizationDivision" => order.organization_division,
      "SoldToParty" => order.sold_to_party,
      "PurchaseOrderByCustomer" => order.purchase_order_by_customer,
      "RequestedDeliveryDate" => Encode.epoch(order.requested_delivery_date),
      "ZZ1_StartShipDate_SDH" => Encode.epoch(order.start_ship_date),
      "ZZ1_EndShipDate_SDH" => Encode.epoch(order.end_ship_date),
      "TransactionCurrency" => order.transaction_currency,
      "CustomerPaymentTerms" => order.customer_payment_terms,
      "IncotermsClassification" => order.incoterms_classification,
      "to_Item" => Encode.children(order.items, &Items.Create.to_odata/1),
      "to_Partner" => Encode.children(order.partners, &Partners.Create.to_odata/1),
      "to_PricingElement" =>
        Encode.children(order.pricing_elements, &PricingElements.Create.to_odata/1),
      "to_Text" => Encode.children(order.texts, &Texts.Create.to_odata/1)
    }
    |> Encode.compact()
  end
end
