defmodule Sap.SalesOrders.Params.List do
  @moduledoc """
  Params for `Sap.SalesOrders.list/1`.

  `:sales_order_type` is required; every other field is optional and narrows the query.

    * `:sold_to_party` - one customer number or a list (a list matches any of them)
    * `:overall_sd_process_status` - header process status
    * `:document_from_date` - orders dated on or after this date
    * `:document_days` - the same window as "the last N days"; ignored when
      `:document_from_date` is set
    * `:customer_references` - matches any of the reference fields SAP may carry a customer's
      purchase order number in
    * `:expand_items` - return each order with its items (default `false`: the expansion
      multiplies the payload by the page size)
    * `:top` - the most orders to return
  """

  @type t :: %__MODULE__{
          sales_order_type: String.t(),
          sold_to_party: String.t() | [String.t()] | nil,
          overall_sd_process_status: String.t() | nil,
          document_from_date: Date.t() | nil,
          document_days: pos_integer() | nil,
          customer_references: [String.t()] | nil,
          expand_items: boolean(),
          top: non_neg_integer() | nil
        }

  @enforce_keys [:sales_order_type]
  defstruct [
    :sales_order_type,
    sold_to_party: nil,
    overall_sd_process_status: nil,
    document_from_date: nil,
    document_days: nil,
    customer_references: nil,
    expand_items: false,
    top: nil
  ]

  defimpl Sap.Odata.Filterable do
    alias Sap.Odata
    alias Sap.Odata.Query
    alias Sap.SalesOrders.SalesOrder

    def to_filter(params) do
      [filters: [{"SalesOrderType", :eq, params.sales_order_type}]]
      |> Query.new()
      |> Query.match("SoldToParty", params.sold_to_party)
      |> Query.match("OverallSDProcessStatus", params.overall_sd_process_status)
      |> Query.on_or_after(
        "SalesOrderDate",
        Odata.Date.since(params.document_from_date, params.document_days)
      )
      |> Query.any_of(SalesOrder.reference_fields(), params.customer_references)
    end
  end
end
