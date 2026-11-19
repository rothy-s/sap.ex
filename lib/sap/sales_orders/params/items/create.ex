defmodule Sap.SalesOrders.Params.Items.Create do
  @moduledoc """
  One item of a sales order being created (`A_SalesOrderItem`, under `to_Item`).

  `:material` and `:requested_quantity` are required. `:requested_quantity` is an integer, a
  `Decimal` or a decimal string; a float raises `ArgumentError`.

  Optional: `:sales_order_item` (the item number; SAP assigns one when left out),
  `:requested_quantity_unit`, `:production_plant`, `:storage_location`, and item-level
  `:pricing_elements` and `:texts`.
  """

  alias Sap.Odata.Encode
  alias Sap.SalesOrders.Params.PricingElements
  alias Sap.SalesOrders.Params.Texts

  @type t :: %__MODULE__{
          material: String.t(),
          requested_quantity: integer() | Decimal.t() | String.t(),
          sales_order_item: String.t() | nil,
          requested_quantity_unit: String.t() | nil,
          production_plant: String.t() | nil,
          storage_location: String.t() | nil,
          pricing_elements: [PricingElements.Create.t()],
          texts: [Texts.Create.t()]
        }

  @enforce_keys [:material, :requested_quantity]
  defstruct [
    :material,
    :requested_quantity,
    sales_order_item: nil,
    requested_quantity_unit: nil,
    production_plant: nil,
    storage_location: nil,
    pricing_elements: [],
    texts: []
  ]

  @doc "The `A_SalesOrderItem` body for a deep insert."
  @spec to_odata(t()) :: map()
  def to_odata(%__MODULE__{} = item) do
    %{
      "SalesOrderItem" => item.sales_order_item,
      "Material" => item.material,
      "RequestedQuantity" => Encode.number(item.requested_quantity),
      "RequestedQuantityUnit" => item.requested_quantity_unit,
      "ProductionPlant" => item.production_plant,
      "StorageLocation" => item.storage_location,
      "to_PricingElement" =>
        Encode.children(item.pricing_elements, &PricingElements.Create.to_odata/1),
      "to_Text" => Encode.children(item.texts, &Texts.Create.to_odata/1)
    }
    |> Encode.compact()
  end
end
