defmodule Sap.SalesOrdersTest do
  use Sap.ApiCase, async: true

  alias Sap.Error
  alias Sap.Odata.Query
  alias Sap.Operation
  alias Sap.SalesOrders
  alias Sap.SalesOrders.Params
  alias Sap.SalesOrders.SalesOrder

  defp item(fields \\ []),
    do: struct!(%Params.Items.Create{material: "SKU-1", requested_quantity: 2}, fields)

  defp order(fields \\ []) do
    struct!(
      %Params.Create{
        sales_order_type: "OR",
        sales_organization: "1000",
        distribution_channel: "10",
        organization_division: "00",
        sold_to_party: "100001",
        items: [item()]
      },
      fields
    )
  end

  describe "create/1 builds" do
    test "a POST to A_SalesOrder that decodes a SalesOrder" do
      assert %Operation{
               service: "API_SALES_ORDER_SRV",
               method: :post,
               path: "/A_SalesOrder",
               shape: :entity,
               receive_timeout: 120_000
             } = operation = SalesOrders.create(order())

      assert Operation.csrf?(operation)

      assert operation.decoder.(%{"SalesOrder" => "1"}) == %SalesOrder{
               sales_order: "1",
               raw: %{"SalesOrder" => "1"}
             }
    end

    test "the smallest body: the five organisational fields and the items, nothing else" do
      assert SalesOrders.create(order()).body == %{
               "SalesOrderType" => "OR",
               "SalesOrganization" => "1000",
               "DistributionChannel" => "10",
               "OrganizationDivision" => "00",
               "SoldToParty" => "100001",
               "to_Item" => [%{"Material" => "SKU-1", "RequestedQuantity" => "2"}]
             }
    end

    test "every header field under its SAP name, with dates as /Date(ms)/" do
      body =
        SalesOrders.create(
          order(
            purchase_order_by_customer: "PO-123",
            requested_delivery_date: ~D[2026-01-01],
            start_ship_date: ~D[2026-01-02],
            end_ship_date: ~D[2026-01-03],
            transaction_currency: "USD",
            customer_payment_terms: "NT30",
            incoterms_classification: "FOB"
          )
        ).body

      assert body["PurchaseOrderByCustomer"] == "PO-123"
      assert body["RequestedDeliveryDate"] == "/Date(1767225600000)/"
      assert body["ZZ1_StartShipDate_SDH"] == "/Date(1767312000000)/"
      assert body["ZZ1_EndShipDate_SDH"] == "/Date(1767398400000)/"
      assert body["TransactionCurrency"] == "USD"
      assert body["CustomerPaymentTerms"] == "NT30"
      assert body["IncotermsClassification"] == "FOB"
    end

    test "every item field, with a Decimal quantity as a plain string" do
      full =
        item(
          sales_order_item: "000010",
          requested_quantity: Decimal.new("2.500"),
          requested_quantity_unit: "PR",
          production_plant: "1010",
          storage_location: "0001"
        )

      assert [
               %{
                 "SalesOrderItem" => "000010",
                 "Material" => "SKU-1",
                 "RequestedQuantity" => "2.500",
                 "RequestedQuantityUnit" => "PR",
                 "ProductionPlant" => "1010",
                 "StorageLocation" => "0001"
               }
             ] == SalesOrders.create(order(items: [full])).body["to_Item"]
    end

    test "partners, pricing elements and texts at header and item level" do
      price = %Params.PricingElements.Create{
        condition_type: "PR00",
        condition_rate_value: Decimal.new("125.00"),
        condition_currency: "USD"
      }

      discount = %Params.PricingElements.Create{condition_type: "ZD01", condition_rate_value: 10}

      note = %Params.Texts.Create{
        language: "EN",
        long_text_id: "0001",
        long_text: "Leave at dock 4"
      }

      body =
        SalesOrders.create(
          order(
            partners: [%Params.Partners.Create{partner_function: "WE", customer: "100002"}],
            pricing_elements: [discount],
            texts: [note],
            items: [item(pricing_elements: [price], texts: [note])]
          )
        ).body

      assert body["to_Partner"] == [%{"PartnerFunction" => "WE", "Customer" => "100002"}]

      assert body["to_PricingElement"] == [
               %{"ConditionType" => "ZD01", "ConditionRateValue" => "10"}
             ]

      assert body["to_Text"] == [
               %{"Language" => "EN", "LongTextID" => "0001", "LongText" => "Leave at dock 4"}
             ]

      assert [item_body] = body["to_Item"]

      assert item_body["to_PricingElement"] == [
               %{
                 "ConditionType" => "PR00",
                 "ConditionRateValue" => "125.00",
                 "ConditionCurrency" => "USD"
               }
             ]

      assert item_body["to_Text"] == [
               %{"Language" => "EN", "LongTextID" => "0001", "LongText" => "Leave at dock 4"}
             ]
    end

    test "empty nested lists are not sent" do
      body = SalesOrders.create(order()).body

      for navigation <- ["to_Partner", "to_PricingElement", "to_Text"] do
        refute Map.has_key?(body, navigation)
        refute Map.has_key?(hd(body["to_Item"]), navigation)
      end
    end
  end

  describe "create/1 refuses" do
    test "an order with no items" do
      assert_raise ArgumentError, ~r/at least one item/, fn ->
        SalesOrders.create(order(items: []))
      end
    end

    test "a float quantity or rate" do
      assert_raise ArgumentError, ~r/got float/, fn ->
        SalesOrders.create(order(items: [item(requested_quantity: 1.5)]))
      end

      assert_raise ArgumentError, ~r/got float/, fn ->
        Params.PricingElements.Create.to_odata(%Params.PricingElements.Create{
          condition_type: "PR00",
          condition_rate_value: 9.99
        })
      end
    end

    test "structs missing their required keys" do
      assert_raise ArgumentError, fn -> struct!(Params.Create, sales_order_type: "OR") end
      assert_raise ArgumentError, fn -> struct!(Params.Items.Create, material: "SKU-1") end
      assert_raise ArgumentError, fn -> struct!(Params.Partners.Create, customer: "1") end

      assert_raise ArgumentError, fn ->
        struct!(Params.PricingElements.Create, condition_type: "PR00")
      end

      assert_raise ArgumentError, fn -> struct!(Params.Texts.Create, language: "EN") end
    end
  end

  describe "create/1 against SAP" do
    test "returns the created order with the number SAP assigned and its items" do
      module =
        start_client(fn conn, _request ->
          json(conn, 201, %{
            "d" => %{
              "SalesOrder" => "12345",
              "SalesOrderType" => "OR",
              "SoldToParty" => "100001",
              "PurchaseOrderByCustomer" => "PO-123",
              "SalesOrderDate" => "/Date(1767225600000)/",
              "ZZ1_StartShipDate_SDH" => "/Date(1767312000000)/",
              "TotalNetAmount" => "250.00",
              "TransactionCurrency" => "USD",
              "to_Item" => %{
                "results" => [
                  %{
                    "SalesOrder" => "12345",
                    "SalesOrderItem" => "10",
                    "Material" => "SKU-1",
                    "RequestedQuantity" => "2"
                  }
                ]
              }
            }
          })
        end)

      assert {:ok, %SalesOrder{} = created} =
               order(purchase_order_by_customer: "PO-123")
               |> SalesOrders.create()
               |> module.request()

      assert created.sales_order == "12345"
      assert created.sales_order_date == ~D[2026-01-01]
      assert created.start_ship_date == ~D[2026-01-02]
      assert created.total_net_amount == "250.00"

      assert [%SalesOrder.Item{sales_order_item: "10", material: "SKU-1", requested_quantity: "2"}] =
               created.items

      assert [request] = received_requests()
      assert request.method == "POST"
      assert request.path == root() <> "/API_SALES_ORDER_SRV/A_SalesOrder"
      assert request.json["to_Item"] == [%{"Material" => "SKU-1", "RequestedQuantity" => "2"}]
      assert is_binary(request.headers["x-csrf-token"])
    end

    test "a rejected order returns SAP's code, message and details" do
      rejection =
        sap_error("V1/801", "Exception raised without specific error", [
          %{
            "code" => "V1/382",
            "message" => "Material SKU-1 is not defined for sales org 1000",
            "severity" => "error",
            "target" => "to_Item"
          }
        ])

      module = start_client(fn conn, _request -> json(conn, 400, rejection) end)

      assert {:error, %Error{kind: :http, status: 400} = error} =
               order() |> SalesOrders.create() |> module.request()

      assert error.code == "V1/801"
      assert error.message == "Material SKU-1 is not defined for sales org 1000"
      assert [%Error.Detail{code: "V1/382", target: "to_Item"}] = error.details
      assert [_sent_once] = received_requests()
    end
  end

  describe "SalesOrder.from_odata/1" do
    test "items are [] when the navigation is deferred or absent, and read from every expanded shape" do
      row = %{"SalesOrder" => "1", "Material" => "A"}

      assert SalesOrder.from_odata(%{"SalesOrder" => "1"}).items == []
      assert SalesOrder.from_odata(%{"to_Item" => %{"__deferred" => %{"uri" => "x"}}}).items == []

      assert [%SalesOrder.Item{material: "A"}] =
               SalesOrder.from_odata(%{"to_Item" => %{"results" => [row]}}).items

      assert [%SalesOrder.Item{material: "A"}] = SalesOrder.from_odata(%{"to_Item" => [row]}).items
      assert [%SalesOrder.Item{material: "A"}] = SalesOrder.from_odata(%{"to_Item" => row}).items
    end

    test "blank strings and unparseable dates decode to nil" do
      order =
        SalesOrder.from_odata(%{
          "SalesOrder" => "1",
          "PurchaseOrderByCustomer" => " ",
          "SalesOrderDate" => "soon"
        })

      assert order.purchase_order_by_customer == nil
      assert order.sales_order_date == nil
    end
  end

  describe "reads" do
    test "get/1 addresses the order by key and expands items by default" do
      operation = SalesOrders.get(%Params.Get{sales_order: "2000001"})

      assert %Operation{method: :get, path: "/A_SalesOrder('2000001')", shape: :entity} = operation
      assert Query.params(operation.query) == [{"$expand", "to_Item"}, {"$format", "json"}]

      plain = SalesOrders.get(%Params.Get{sales_order: "O'1", expand_items: false})
      assert plain.path == "/A_SalesOrder('O''1')"
      assert Query.params(plain.query) == [{"$format", "json"}]
    end

    test "list/1 always filters by type and adds each given criterion" do
      operation =
        SalesOrders.list(%Params.List{
          sales_order_type: "OR",
          sold_to_party: ["100001", "100002"],
          overall_sd_process_status: "A",
          document_from_date: ~D[2026-01-01],
          customer_references: ["PO-1"],
          expand_items: true,
          top: 50
        })

      assert %Operation{path: "/A_SalesOrder", shape: :collection} = operation
      params = Map.new(Query.params(operation.query))

      assert params["$filter"] ==
               "SalesOrderType eq 'OR' and (SoldToParty eq '100001' or SoldToParty eq '100002') and " <>
                 "OverallSDProcessStatus eq 'A' and SalesOrderDate ge datetime'2026-01-01T00:00:00' and " <>
                 "(PurchaseOrderByCustomer eq 'PO-1' or AssignmentReference eq 'PO-1' or " <>
                 "ReferenceSDDocument eq 'PO-1' or ExternalDocumentID eq 'PO-1')"

      assert params["$expand"] == "to_Item"
      assert params["$top"] == "50"
    end

    test "list/1 with only a type neither expands nor limits" do
      operation = SalesOrders.list(%Params.List{sales_order_type: "OR"})

      assert Query.params(operation.query) == [
               {"$filter", "SalesOrderType eq 'OR'"},
               {"$format", "json"}
             ]
    end

    test "list_items/1 queries items directly" do
      operation =
        SalesOrders.list_items(%Params.Items.List{
          sales_order: "1",
          material: ["A", "B"],
          sd_process_status: "C",
          top: 5
        })

      assert %Operation{path: "/A_SalesOrderItem", shape: :collection} = operation

      assert Query.params(operation.query) == [
               {"$filter",
                "SalesOrder eq '1' and (Material eq 'A' or Material eq 'B') and SDProcessStatus eq 'C'"},
               {"$top", "5"},
               {"$format", "json"}
             ]

      assert Query.params(SalesOrders.list_items(%Params.Items.List{}).query) == [
               {"$format", "json"}
             ]
    end

    test "a missing order is :not_found" do
      module =
        start_client(fn conn, _request ->
          json(conn, 404, sap_error("/IWBEP/CM_MGW_RT/020", "Resource not found"))
        end)

      assert {:error, %Error{kind: :not_found}} =
               %Params.Get{sales_order: "9"} |> SalesOrders.get() |> module.request()
    end
  end
end
