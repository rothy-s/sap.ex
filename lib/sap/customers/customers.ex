defmodule Sap.Customers do
  @moduledoc """
  SAP customers (`A_Customer` and related entities on `API_BUSINESS_PARTNER`).

  Every function here is pure: it takes a params struct and returns a `Sap.Operation` for a
  client module to run.

      %Sap.Customers.Params.Get{customer: "100001", expand: [:sales_areas, :partner_functions]}
      |> Sap.Customers.get()
      |> MyApp.Sap.request()
      #=> {:ok, %Sap.Customers.Customer{customer: "100001", sales_areas: [...]}}

  A customer's sales areas (currency, payment terms, incoterms) and their partner functions
  (ship-to, bill-to, payer) are loaded only when asked for through `:expand`. Addresses belong to
  the business partner and are read with `list_addresses/1`.
  """

  alias Sap.Customers.Address
  alias Sap.Customers.Customer
  alias Sap.Customers.Params
  alias Sap.Odata.Encode
  alias Sap.Odata.Filterable
  alias Sap.Odata.Query
  alias Sap.Operation

  @service "API_BUSINESS_PARTNER"
  @entity "/A_Customer"
  @partner_entity "/A_BusinessPartner"
  @address_nav "/to_BusinessPartnerAddress"

  @expansions %{
    sales_areas: "to_CustomerSalesArea",
    partner_functions: "to_CustomerSalesArea/to_PartnerFunction"
  }

  @doc "The OData service customers live on."
  @spec service() :: Operation.service()
  def service, do: @service

  @doc """
  One customer, by number. A number SAP does not have is `%Sap.Error{kind: :not_found}`.
  """
  @spec get(Params.Get.t()) :: Operation.t()
  def get(%Params.Get{} = params) do
    %Operation{
      service: @service,
      path: @entity <> Encode.key(params.customer),
      query: expand(Query.new(), params.expand),
      shape: :entity,
      decoder: &Customer.from_odata/1
    }
  end

  @doc """
  The customers with the given numbers. Unknown numbers are absent from the result, not an error.

  The numbers become one OR filter, so chunk a long list: a few dozen per call is safe. An empty
  `:customers` raises `ArgumentError`.
  """
  @spec list(Params.List.t()) :: Operation.t()
  def list(%Params.List{customers: [_ | _]} = params) do
    %Operation{
      service: @service,
      path: @entity,
      query: params |> Filterable.to_filter() |> expand(params.expand),
      shape: :collection,
      decoder: &Customer.from_odata/1,
      receive_timeout: 120_000
    }
  end

  def list(%Params.List{}) do
    raise ArgumentError, "listing customers needs at least one number in :customers"
  end

  @doc """
  The addresses of one business partner.

  A customer and its business partner share a number in a standard setup, so a customer number
  is the usual argument.
  """
  @spec list_addresses(Params.Addresses.List.t()) :: Operation.t()
  def list_addresses(%Params.Addresses.List{} = params) do
    %Operation{
      service: @service,
      path: @partner_entity <> Encode.key(params.business_partner) <> @address_nav,
      query: Query.new(),
      shape: :collection,
      decoder: &Address.from_odata/1
    }
  end

  defp expand(query, []), do: query

  defp expand(query, expansions) when is_list(expansions) do
    Query.expand(query, expansions |> Enum.map(&navigation/1) |> Enum.uniq())
  end

  defp navigation(expansion) do
    Map.get(@expansions, expansion) ||
      raise ArgumentError,
            "unknown customer expansion #{inspect(expansion)}; " <>
              "expected one of #{inspect(Map.keys(@expansions))}"
  end
end
