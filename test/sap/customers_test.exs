defmodule Sap.CustomersTest do
  use Sap.ApiCase, async: true

  alias Sap.Customers
  alias Sap.Customers.Address
  alias Sap.Customers.Customer
  alias Sap.Customers.Params
  alias Sap.Customers.PartnerFunction
  alias Sap.Customers.SalesArea
  alias Sap.Error
  alias Sap.Odata.Query
  alias Sap.Operation

  @customer_row %{
    "Customer" => "100001",
    "CustomerName" => "Acme Shoes",
    "CustomerAccountGroup" => "CUST",
    "OrderIsBlockedForCustomer" => "",
    "DeliveryIsBlocked" => "01",
    "BillingIsBlockedForCustomer" => "",
    "PostingIsBlocked" => false,
    "DeletionIndicator" => false,
    "to_CustomerSalesArea" => %{
      "results" => [
        %{
          "Customer" => "100001",
          "SalesOrganization" => "1000",
          "DistributionChannel" => "10",
          "Division" => "00",
          "Currency" => "USD",
          "CustomerPaymentTerms" => "NT30",
          "IncotermsClassification" => "FOB",
          "IncotermsLocation1" => "Oakland",
          "ShippingCondition" => "01",
          "to_PartnerFunction" => %{
            "results" => [
              %{
                "Customer" => "100001",
                "SalesOrganization" => "1000",
                "PartnerCounter" => "0",
                "PartnerFunction" => "WE",
                "BPCustomerNumber" => "100002",
                "DefaultPartner" => true
              }
            ]
          }
        }
      ]
    }
  }

  describe "get/1" do
    test "addresses the customer by key with no expansion by default" do
      operation = Customers.get(%Params.Get{customer: "100001"})

      assert %Operation{
               service: "API_BUSINESS_PARTNER",
               method: :get,
               path: "/A_Customer('100001')",
               shape: :entity
             } = operation

      assert Query.params(operation.query) == [{"$format", "json"}]
    end

    test "expands sales areas, and partner functions through them" do
      sales_areas = Customers.get(%Params.Get{customer: "1", expand: [:sales_areas]})
      assert {"$expand", "to_CustomerSalesArea"} in Query.params(sales_areas.query)

      both = Customers.get(%Params.Get{customer: "1", expand: [:sales_areas, :partner_functions]})

      assert {"$expand", "to_CustomerSalesArea,to_CustomerSalesArea/to_PartnerFunction"} in Query.params(
               both.query
             )
    end

    test "an unknown expansion raises" do
      assert_raise ArgumentError, ~r/unknown customer expansion :addresses/, fn ->
        Customers.get(%Params.Get{customer: "1", expand: [:addresses]})
      end
    end

    test "returns the customer with nested sales areas and partner functions" do
      module = start_client(fn conn, _request -> json(conn, %{"d" => @customer_row}) end)

      assert {:ok, %Customer{} = customer} =
               %Params.Get{customer: "100001", expand: [:sales_areas, :partner_functions]}
               |> Customers.get()
               |> module.request()

      assert customer.customer == "100001"
      assert customer.name == "Acme Shoes"
      assert customer.account_group == "CUST"
      assert customer.order_block == nil
      assert customer.delivery_block == "01"
      assert customer.posting_blocked == false
      assert customer.marked_for_deletion == false

      assert [%SalesArea{} = area] = customer.sales_areas
      assert area.sales_organization == "1000"
      assert area.currency == "USD"
      assert area.customer_payment_terms == "NT30"
      assert area.incoterms_classification == "FOB"
      assert area.incoterms_location == "Oakland"

      assert [
               %PartnerFunction{
                 partner_function: "WE",
                 bp_customer_number: "100002",
                 default_partner: true
               }
             ] =
               area.partner_functions

      assert [request] = received_requests()
      assert request.path == root() <> "/API_BUSINESS_PARTNER/A_Customer('100001')"

      assert request.query["$expand"] ==
               "to_CustomerSalesArea,to_CustomerSalesArea/to_PartnerFunction"
    end

    test "a customer SAP does not have is :not_found" do
      module =
        start_client(fn conn, _request ->
          json(conn, 404, sap_error("/IWBEP/CM_MGW_RT/020", "Resource not found"))
        end)

      assert {:error, %Error{kind: :not_found}} =
               %Params.Get{customer: "9"} |> Customers.get() |> module.request()
    end
  end

  describe "list/1" do
    test "filters by the given numbers" do
      operation = Customers.list(%Params.List{customers: ["1", "2"], expand: [:sales_areas]})

      assert %Operation{path: "/A_Customer", shape: :collection} = operation

      assert Query.params(operation.query) == [
               {"$filter", "(Customer eq '1' or Customer eq '2')"},
               {"$expand", "to_CustomerSalesArea"},
               {"$format", "json"}
             ]
    end

    test "an empty list raises" do
      assert_raise ArgumentError, ~r/at least one number/, fn ->
        Customers.list(%Params.List{customers: []})
      end
    end

    test "returns the customers found, dropping rows with no number" do
      rows = [%{"Customer" => "1", "CustomerName" => "One"}, %{"Customer" => ""}]
      module = start_client(fn conn, _request -> json(conn, %{"d" => %{"results" => rows}}) end)

      assert {:ok, [%Customer{customer: "1", name: "One", sales_areas: []}]} =
               %Params.List{customers: ["1", "2"]} |> Customers.list() |> module.request()
    end
  end

  describe "list_addresses/1" do
    test "reads the addresses under the business partner" do
      operation = Customers.list_addresses(%Params.Addresses.List{business_partner: "100001"})

      assert %Operation{
               path: "/A_BusinessPartner('100001')/to_BusinessPartnerAddress",
               shape: :collection
             } = operation
    end

    test "returns addresses, dropping rows without a key" do
      rows = [
        %{
          "BusinessPartner" => "100001",
          "AddressID" => "25001",
          "FullName" => "Acme Shoes",
          "StreetName" => "Main St",
          "HouseNumber" => "12",
          "CityName" => "Oakland",
          "Region" => "CA",
          "PostalCode" => "94607",
          "Country" => "US",
          "ValidityStartDate" => "/Date(1767225600000+0000)/"
        },
        %{"BusinessPartner" => "100001"}
      ]

      module = start_client(fn conn, _request -> json(conn, %{"d" => %{"results" => rows}}) end)

      assert {:ok, [%Address{} = address]} =
               %Params.Addresses.List{business_partner: "100001"}
               |> Customers.list_addresses()
               |> module.request()

      assert address.address_id == "25001"
      assert address.street_name == "Main St"
      assert address.city_name == "Oakland"
      assert address.postal_code == "94607"
      assert address.country == "US"
      assert address.validity_start_date == ~D[2026-01-01]
    end
  end

  describe "decoding" do
    test "the customer name falls back to the full name" do
      assert Customer.from_odata(%{"Customer" => "1", "CustomerFullName" => "Org"}).name == "Org"
      assert Customer.from_odata(%{"Customer" => "1"}).name == nil
      assert Customer.from_odata(%{"CustomerName" => "No number"}) == nil
    end

    test "legacy X flags decode as booleans and the older incoterms field is read" do
      assert Customer.from_odata(%{"Customer" => "1", "PostingIsBlocked" => "X"}).posting_blocked ==
               true

      assert SalesArea.from_odata(%{"IncotermsTransferLocation" => "Reno"}).incoterms_location ==
               "Reno"

      assert SalesArea.from_odata(%{}).partner_functions == []
    end
  end
end
