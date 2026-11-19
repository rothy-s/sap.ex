defmodule Sap.SalesOrders do
  @moduledoc """
  SAP sales orders (`A_SalesOrder` and `A_SalesOrderItem` on `API_SALES_ORDER_SRV`).

  Every function here is pure: it takes a params struct and returns a `Sap.Operation` for a
  client module to run.

      %Sap.SalesOrders.Params.Create{
        sales_order_type: "OR",
        sales_organization: "1000",
        distribution_channel: "10",
        organization_division: "00",
        sold_to_party: "100001",
        items: [%Params.Items.Create{material: "SKU-1", requested_quantity: 2}]
      }
      |> Sap.SalesOrders.create()
      |> MyApp.Sap.request()
      #=> {:ok, %Sap.SalesOrders.SalesOrder{sales_order: "12345"}}
  """

  alias Sap.Odata.Encode
  alias Sap.Odata.Filterable
  alias Sap.Odata.Query
  alias Sap.Operation
  alias Sap.SalesOrders.Params
  alias Sap.SalesOrders.SalesOrder
  alias Sap.SalesOrders.SalesOrder.Item

  @service "API_SALES_ORDER_SRV"
  @entity "/A_SalesOrder"
  @item_entity "/A_SalesOrderItem"
  @timeout 120_000

  @doc "The OData service sales orders live on."
  @spec service() :: Operation.service()
  def service, do: @service

  @doc """
  Creates a sales order, deep-inserting the header with its items, partners, pricing elements
  and texts in one POST.

  Returns the created order as a `Sap.SalesOrders.SalesOrder`, whose `:sales_order` is the number
  SAP assigned.

  > #### This creates a real document {: .warning}
  >
  > SAP has no idempotency key and no dry run. The library sends this request once. If it fails
  > with `:timeout`, `:transport` or a 5xx, SAP may still have created the order: look it up (for
  > example by `:purchase_order_by_customer`) before sending it again.

  At least one item is required; an empty `:items` raises `ArgumentError`.
  """
  @spec create(Params.Create.t()) :: Operation.t()
  def create(%Params.Create{items: [_ | _]} = params) do
    %Operation{
      service: @service,
      method: :post,
      path: @entity,
      body: Params.Create.to_odata(params),
      shape: :entity,
      decoder: &SalesOrder.from_odata/1,
      receive_timeout: @timeout
    }
  end

  def create(%Params.Create{}) do
    raise ArgumentError, "a sales order needs at least one item in :items"
  end

  @doc """
  One sales order, by number. A number SAP does not have is `%Sap.Error{kind: :not_found}`.
  """
  @spec get(Params.Get.t()) :: Operation.t()
  def get(%Params.Get{} = params) do
    %Operation{
      service: @service,
      path: @entity <> Encode.key(params.sales_order),
      query: expansion(Query.new(), params.expand_items),
      shape: :entity,
      decoder: &SalesOrder.from_odata/1,
      receive_timeout: @timeout
    }
  end

  @doc "Sales orders matching the given criteria."
  @spec list(Params.List.t()) :: Operation.t()
  def list(%Params.List{} = params) do
    query =
      params
      |> Filterable.to_filter()
      |> expansion(params.expand_items)
      |> Query.top(params.top)

    %Operation{
      service: @service,
      path: @entity,
      query: query,
      shape: :collection,
      decoder: &SalesOrder.from_odata/1,
      receive_timeout: @timeout
    }
  end

  @doc """
  Sales order items, queried directly rather than through their headers.

  Each `Sap.SalesOrders.SalesOrder.Item` carries its own `:sales_order`.
  """
  @spec list_items(Params.Items.List.t()) :: Operation.t()
  def list_items(%Params.Items.List{} = params) do
    %Operation{
      service: @service,
      path: @item_entity,
      query: params |> Filterable.to_filter() |> Query.top(params.top),
      shape: :collection,
      decoder: &Item.from_odata/1,
      receive_timeout: @timeout
    }
  end

  defp expansion(query, true), do: Query.expand(query, SalesOrder.item_nav())
  defp expansion(query, false), do: query
end
