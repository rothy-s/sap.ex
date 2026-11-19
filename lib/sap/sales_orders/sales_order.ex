defmodule Sap.SalesOrders.SalesOrder do
  @moduledoc """
  One SAP sales order header (an `A_SalesOrder` row).

  Dates decode to `Date` structs. Amounts stay the strings SAP sent: OData V2 serialises
  `Edm.Decimal` as a string so nothing rounds in transit, and this library does not reinterpret
  values. Build a `Decimal` where you need arithmetic.

  `:items` is filled from `$expand=to_Item` and is `[]` when the query did not ask for it.
  `:start_ship_date` and `:end_ship_date` are the custom fields `ZZ1_StartShipDate_SDH` and
  `ZZ1_EndShipDate_SDH`. `:raw` is the row as SAP sent it.
  """

  alias Sap.Odata.Decode
  alias Sap.SalesOrders.SalesOrder.Item

  @type t :: %__MODULE__{
          sales_order: String.t() | nil,
          sales_order_type: String.t() | nil,
          sold_to_party: String.t() | nil,
          sales_organization: String.t() | nil,
          distribution_channel: String.t() | nil,
          organization_division: String.t() | nil,
          purchase_order_by_customer: String.t() | nil,
          sales_order_date: Date.t() | nil,
          requested_delivery_date: Date.t() | nil,
          start_ship_date: Date.t() | nil,
          end_ship_date: Date.t() | nil,
          customer_payment_terms: String.t() | nil,
          incoterms_classification: String.t() | nil,
          overall_sd_process_status: String.t() | nil,
          overall_delivery_status: String.t() | nil,
          total_net_amount: String.t() | nil,
          transaction_currency: String.t() | nil,
          items: [Item.t()],
          raw: map()
        }

  defstruct sales_order: nil,
            sales_order_type: nil,
            sold_to_party: nil,
            sales_organization: nil,
            distribution_channel: nil,
            organization_division: nil,
            purchase_order_by_customer: nil,
            sales_order_date: nil,
            requested_delivery_date: nil,
            start_ship_date: nil,
            end_ship_date: nil,
            customer_payment_terms: nil,
            incoterms_classification: nil,
            overall_sd_process_status: nil,
            overall_delivery_status: nil,
            total_net_amount: nil,
            transaction_currency: nil,
            items: [],
            raw: %{}

  # A customer's reference number can land in any of these, depending on how the order was created.
  @reference_fields ~w(
    PurchaseOrderByCustomer
    AssignmentReference
    ReferenceSDDocument
    ExternalDocumentID
  )

  @item_nav "to_Item"

  @doc "Decodes one `A_SalesOrder` row, including its `to_Item` expansion when present."
  @spec from_odata(map()) :: t()
  def from_odata(row) when is_map(row) do
    %__MODULE__{
      sales_order: Decode.string(row["SalesOrder"]),
      sales_order_type: Decode.string(row["SalesOrderType"]),
      sold_to_party: Decode.string(row["SoldToParty"]),
      sales_organization: Decode.string(row["SalesOrganization"]),
      distribution_channel: Decode.string(row["DistributionChannel"]),
      organization_division: Decode.string(row["OrganizationDivision"]),
      purchase_order_by_customer: Decode.string(row["PurchaseOrderByCustomer"]),
      sales_order_date: Decode.date(row["SalesOrderDate"]),
      requested_delivery_date: Decode.date(row["RequestedDeliveryDate"]),
      start_ship_date: Decode.date(row["ZZ1_StartShipDate_SDH"]),
      end_ship_date: Decode.date(row["ZZ1_EndShipDate_SDH"]),
      customer_payment_terms: Decode.string(row["CustomerPaymentTerms"]),
      incoterms_classification: Decode.string(row["IncotermsClassification"]),
      overall_sd_process_status: Decode.string(row["OverallSDProcessStatus"]),
      overall_delivery_status: Decode.string(row["OverallDeliveryStatus"]),
      total_net_amount: Decode.string(row["TotalNetAmount"]),
      transaction_currency: Decode.string(row["TransactionCurrency"]),
      items: row |> Decode.nav(@item_nav) |> Enum.map(&Item.from_odata/1),
      raw: row
    }
  end

  @doc "The fields a customer's reference number may appear in."
  @spec reference_fields() :: [String.t()]
  def reference_fields, do: @reference_fields

  @doc "The navigation property carrying the order's items."
  @spec item_nav() :: String.t()
  def item_nav, do: @item_nav
end
