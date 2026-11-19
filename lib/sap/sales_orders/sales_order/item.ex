defmodule Sap.SalesOrders.SalesOrder.Item do
  @moduledoc """
  One sales order item (an `A_SalesOrderItem` row).

  Reached through `$expand=to_Item` on a header or directly from `Sap.SalesOrders.list_items/1`.
  Quantities stay the strings SAP sent; see `Sap.SalesOrders.SalesOrder`.
  """

  alias Sap.Odata.Decode

  @type t :: %__MODULE__{
          sales_order: String.t() | nil,
          sales_order_item: String.t() | nil,
          material: String.t() | nil,
          production_plant: String.t() | nil,
          storage_location: String.t() | nil,
          requested_quantity: String.t() | nil,
          requested_quantity_unit: String.t() | nil,
          confd_deliv_qty_in_order_qty_unit: String.t() | nil,
          sd_process_status: String.t() | nil,
          sales_order_item_category: String.t() | nil,
          delivery_status: String.t() | nil,
          raw: map()
        }

  defstruct sales_order: nil,
            sales_order_item: nil,
            material: nil,
            production_plant: nil,
            storage_location: nil,
            requested_quantity: nil,
            requested_quantity_unit: nil,
            confd_deliv_qty_in_order_qty_unit: nil,
            sd_process_status: nil,
            sales_order_item_category: nil,
            delivery_status: nil,
            raw: %{}

  @doc "Decodes one `A_SalesOrderItem` row."
  @spec from_odata(map()) :: t()
  def from_odata(row) when is_map(row) do
    %__MODULE__{
      sales_order: Decode.string(row["SalesOrder"]),
      sales_order_item: Decode.string(row["SalesOrderItem"]),
      material: Decode.string(row["Material"]),
      production_plant: Decode.string(row["ProductionPlant"]),
      storage_location: Decode.string(row["StorageLocation"]),
      requested_quantity: Decode.string(row["RequestedQuantity"]),
      requested_quantity_unit: Decode.string(row["RequestedQuantityUnit"]),
      confd_deliv_qty_in_order_qty_unit: Decode.string(row["ConfdDelivQtyInOrderQtyUnit"]),
      sd_process_status: Decode.string(row["SDProcessStatus"]),
      sales_order_item_category: Decode.string(row["SalesOrderItemCategory"]),
      delivery_status: Decode.string(row["DeliveryStatus"]),
      raw: row
    }
  end
end
