defmodule Sap.Integration.Client do
  @moduledoc false
  use Sap.Client, otp_app: :sap
end

defmodule Sap.Integration.SandboxTest do
  @moduledoc """
  Runs against a real SAP sandbox. Excluded by default.

      mix test --only integration            # reads only
      mix test --only integration_write      # creates a real sales order

  Credentials and master data come from the gitignored `config/test.override.exs`:

      import Config

      config :sap, Sap.Integration.Client,
        base_url: "https://sap-sandbox.example.com",
        sap_client: "110",
        user: "...",
        password: "..."

      config :sap, :integration,
        customer: "100001",
        sales_order_type: "OR",
        sales_organization: "1000",
        distribution_channel: "10",
        organization_division: "00",
        material: "SKU-1"
  """

  use ExUnit.Case, async: false

  alias Sap.Customers
  alias Sap.Integration.Client
  alias Sap.Operation
  alias Sap.SalesOrders
  alias Sap.SalesOrders.Params

  # Every SAP field name the library reads or writes, by entity type. `$metadata` is the
  # authority: a name missing here is a field the library has wrong.
  @fields %{
    "API_SALES_ORDER_SRV" => %{
      "A_SalesOrderType" =>
        ~w(SalesOrder SalesOrderType SalesOrganization DistributionChannel OrganizationDivision
           SoldToParty PurchaseOrderByCustomer SalesOrderDate RequestedDeliveryDate
           TransactionCurrency CustomerPaymentTerms IncotermsClassification OverallSDProcessStatus
           OverallDeliveryStatus TotalNetAmount ZZ1_StartShipDate_SDH ZZ1_EndShipDate_SDH
           to_Item to_Partner to_PricingElement to_Text),
      "A_SalesOrderItemType" =>
        ~w(SalesOrder SalesOrderItem Material RequestedQuantity RequestedQuantityUnit
           ProductionPlant StorageLocation ConfdDelivQtyInOrderQtyUnit SDProcessStatus
           SalesOrderItemCategory DeliveryStatus
           to_PricingElement to_Text),
      "A_SalesOrderHeaderPartnerType" => ~w(PartnerFunction Customer),
      "A_SalesOrderHeaderPrElementType" => ~w(ConditionType ConditionRateValue ConditionCurrency),
      "A_SalesOrderItemPrElementType" => ~w(ConditionType ConditionRateValue ConditionCurrency),
      "A_SalesOrderTextType" => ~w(Language LongTextID LongText),
      "A_SalesOrderItemTextType" => ~w(Language LongTextID LongText)
    },
    "API_BUSINESS_PARTNER" => %{
      "A_CustomerType" =>
        ~w(Customer CustomerName CustomerAccountGroup OrderIsBlockedForCustomer DeliveryIsBlocked
           BillingIsBlockedForCustomer PostingIsBlocked DeletionIndicator to_CustomerSalesArea),
      "A_CustomerSalesAreaType" =>
        ~w(Customer SalesOrganization DistributionChannel Division Currency CustomerPaymentTerms
           IncotermsClassification ShippingCondition DeliveryPriority SupplyingPlant
           CustomerPricingProcedure OrderIsBlockedForCustomer to_PartnerFunction),
      "A_CustSalesPartnerFuncType" =>
        ~w(Customer SalesOrganization DistributionChannel Division PartnerCounter PartnerFunction
           BPCustomerNumber CustomerPartnerDescription DefaultPartner),
      "A_BusinessPartnerAddressType" =>
        ~w(BusinessPartner AddressID FullName StreetName AdditionalStreetPrefixName
           AdditionalStreetSuffixName HouseNumber CityName Region PostalCode Country
           ValidityStartDate ValidityEndDate)
    }
  }

  setup_all do
    client = Application.get_env(:sap, Client, [])
    data = Application.get_env(:sap, :integration, [])

    if client == [] do
      raise "integration tests need config/test.override.exs; see this file's moduledoc"
    end

    filled!(client, [:base_url, :sap_client, :user, :password])
    filled!(data, [:customer])

    start_supervised!(Client)
    %{data: Map.new(Application.fetch_env!(:sap, :integration))}
  end

  describe "$metadata" do
    for {service, entities} <- @fields, {entity, fields} <- entities do
      @tag :integration
      test "#{service} #{entity} has every field the library uses" do
        metadata = metadata(unquote(service))
        entity = entity_type(metadata, unquote(entity))

        missing = Enum.reject(unquote(fields), &String.contains?(entity, ~s(Name="#{&1}")))
        assert missing == [], "#{unquote(entity)} has no #{inspect(missing)}"
      end
    end
  end

  @tag :integration
  test "reads a customer with its sales areas and partner functions", %{data: data} do
    assert {:ok, %Customers.Customer{} = customer} =
             %Customers.Params.Get{
               customer: data.customer,
               expand: [:sales_areas, :partner_functions]
             }
             |> Customers.get()
             |> Client.request()

    assert customer.customer == data.customer
    assert is_binary(customer.name)
    assert [%Customers.SalesArea{} | _] = customer.sales_areas
  end

  @tag :integration
  test "reads a customer's addresses", %{data: data} do
    assert {:ok, addresses} =
             %Customers.Params.Addresses.List{business_partner: data.customer}
             |> Customers.list_addresses()
             |> Client.request()

    assert Enum.all?(addresses, &match?(%Customers.Address{}, &1))
  end

  @tag :integration
  test "a customer SAP does not have is :not_found" do
    assert {:error, %Sap.Error{kind: :not_found}} =
             %Customers.Params.Get{customer: "ZZNOPE"} |> Customers.get() |> Client.request()
  end

  @tag :integration_write
  test "creates a sales order and reads it back", %{data: data} do
    filled!(Keyword.new(data), [
      :sales_order_type,
      :sales_organization,
      :distribution_channel,
      :organization_division,
      :material
    ])

    reference = "SAPLIB-#{System.os_time(:second)}"

    params = %Params.Create{
      sales_order_type: data.sales_order_type,
      sales_organization: data.sales_organization,
      distribution_channel: data.distribution_channel,
      organization_division: data.organization_division,
      sold_to_party: data.customer,
      purchase_order_by_customer: reference,
      requested_delivery_date: Date.add(Date.utc_today(), 14),
      items: [%Params.Items.Create{material: data.material, requested_quantity: 1}]
    }

    assert {:ok, %SalesOrders.SalesOrder{sales_order: number}} =
             params |> SalesOrders.create() |> Client.request()

    assert is_binary(number)

    assert {:ok, %SalesOrders.SalesOrder{purchase_order_by_customer: ^reference, items: [_item]}} =
             %SalesOrders.Params.Get{sales_order: number} |> SalesOrders.get() |> Client.request()
  end

  # Each test needs only some of the settings, so reads can run before the write test's master
  # data is known.
  defp filled!(settings, keys) do
    case Enum.filter(keys, &(settings[&1] in [nil, "", "CHANGE_ME"])) do
      [] -> :ok
      missing -> raise "config/test.override.exs: fill in #{inspect(missing)}"
    end
  end

  defp metadata(service) do
    operation = %Operation{service: service, path: "/$metadata", parser: :text, shape: :raw}
    assert {:ok, xml} = Client.request(operation)
    xml
  end

  defp entity_type(metadata, name) do
    case Regex.run(~r/<EntityType Name="#{name}".*?<\/EntityType>/s, metadata) do
      [entity] -> entity
      nil -> flunk("the service has no entity type #{name}")
    end
  end
end
