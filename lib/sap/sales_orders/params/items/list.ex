defmodule Sap.SalesOrders.Params.Items.List do
  @moduledoc """
  Params for `Sap.SalesOrders.list_items/1`: sales order items queried directly.

  All fields are optional. An empty struct asks for every item the service will return, so pair
  it with `:top` or run it through `c:Sap.Client.stream/3`.

    * `:sales_order` - one order number or a list
    * `:material` - one material or a list
    * `:sd_process_status` - item process status
    * `:top` - the most items to return
  """

  @type t :: %__MODULE__{
          sales_order: String.t() | [String.t()] | nil,
          material: String.t() | [String.t()] | nil,
          sd_process_status: String.t() | nil,
          top: non_neg_integer() | nil
        }

  defstruct sales_order: nil, material: nil, sd_process_status: nil, top: nil

  defimpl Sap.Odata.Filterable do
    alias Sap.Odata.Query

    def to_filter(params) do
      Query.new()
      |> Query.match("SalesOrder", params.sales_order)
      |> Query.match("Material", params.material)
      |> Query.match("SDProcessStatus", params.sd_process_status)
    end
  end
end
