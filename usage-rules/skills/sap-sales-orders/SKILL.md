---
name: sap-sales-orders
description: "Use when creating, reading or listing SAP sales orders with `Sap.SalesOrders`, building `Sap.SalesOrders.Params.Create` or its items, partners, pricing elements or texts, or handling a failed or timed-out sales order create."
---

# SAP sales orders

Service `API_SALES_ORDER_SRV`. Module `Sap.SalesOrders`.

## Create

```elixir
alias Sap.SalesOrders.Params

%Params.Create{
  sales_order_type: "OR",
  sales_organization: "1000",
  distribution_channel: "10",
  organization_division: "00",
  sold_to_party: "100001",
  purchase_order_by_customer: "PO-123",
  requested_delivery_date: ~D[2026-12-01],
  partners: [%Params.Partners.Create{partner_function: "WE", customer: "100002"}],
  texts: [%Params.Texts.Create{language: "EN", long_text_id: "0001", long_text: "Dock 4"}],
  items: [
    %Params.Items.Create{
      material: "SKU-1",
      requested_quantity: 2,
      pricing_elements: [
        %Params.PricingElements.Create{condition_type: "PR00", condition_rate_value: Decimal.new("125.00")}
      ]
    }
  ]
}
|> Sap.SalesOrders.create()
|> MyApp.Sap.request()
#=> {:ok, %Sap.SalesOrders.SalesOrder{sales_order: "12345", items: [...]}}
```

- At least one item is required; an empty `:items` raises `ArgumentError`.
- A field left `nil` and a list left empty are not sent; SAP applies its defaults.
- `start_ship_date` and `end_ship_date` are the custom header fields.

## A create that fails

A create is sent once and never retried.

| Result | Meaning | What to do |
|---|---|---|
| `{:error, %Sap.Error{kind: :http, status: 400}}` | SAP rejected the order. Nothing was created. | Read `code`, `message` and `details`; fix the data. |
| `kind: :timeout`, `:transport`, or `:http` with a 5xx | **Unknown.** SAP may have created it. | Look the order up by `purchase_order_by_customer` before sending again. |
| `kind: :csrf` | The request never reached SAP's processing. | Safe to send again later. |

Looking an order up by the customer's reference:

```elixir
%Params.List{sales_order_type: "OR", customer_references: ["PO-123"]}
|> Sap.SalesOrders.list()
|> MyApp.Sap.request()
```

## Read

- `Sap.SalesOrders.get(%Params.Get{sales_order: "12345"})` returns the order with its items. A
  missing order is `%Sap.Error{kind: :not_found}`.
- `Sap.SalesOrders.list(%Params.List{sales_order_type: "OR", ...})`: `:sales_order_type` is
  required. `:expand_items` defaults to `false`.
- `Sap.SalesOrders.list_items(%Params.Items.List{...})` queries items directly.
- For large result sets use `MyApp.Sap.stream(operation, acc, reducer)`.

## Fields

Params (required fields first; everything after the semicolon is optional):

| Struct | Fields |
|---|---|
| `Params.Create` | `sales_order_type`, `sales_organization`, `distribution_channel`, `organization_division`, `sold_to_party`, `items`; `purchase_order_by_customer`, `requested_delivery_date`, `start_ship_date`, `end_ship_date`, `transaction_currency`, `customer_payment_terms`, `incoterms_classification`, `partners`, `pricing_elements`, `texts` |
| `Params.Items.Create` | `material`, `requested_quantity`; `sales_order_item`, `requested_quantity_unit`, `production_plant`, `storage_location`, `pricing_elements`, `texts` |
| `Params.Partners.Create` | `partner_function`, `customer` |
| `Params.PricingElements.Create` | `condition_type`, `condition_rate_value`; `condition_currency` |
| `Params.Texts.Create` | `language`, `long_text_id`, `long_text` |
| `Params.Get` | `sales_order`; `expand_items` (default `true`) |
| `Params.List` | `sales_order_type`; `sold_to_party`, `overall_sd_process_status`, `document_from_date`, `document_days`, `customer_references`, `expand_items`, `top` |
| `Params.Items.List` | all optional: `sales_order`, `material`, `sd_process_status`, `top` |

Partner function codes: `"WE"` ship-to, `"RE"` bill-to, `"RG"` payer.

`customer_references` matches the customer's reference in any of four SAP fields, not only the
purchase order number. Compare `purchase_order_by_customer` on the result when you need an exact
match.

Results. Every field is a string or `nil` unless noted; each struct also has `:raw`.

| Struct | Fields |
|---|---|
| `Sap.SalesOrders.SalesOrder` | `sales_order`, `sales_order_type`, `sold_to_party`, `sales_organization`, `distribution_channel`, `organization_division`, `purchase_order_by_customer`, `sales_order_date` (`Date`), `requested_delivery_date` (`Date`), `start_ship_date` (`Date`), `end_ship_date` (`Date`), `customer_payment_terms`, `incoterms_classification`, `overall_sd_process_status`, `overall_delivery_status`, `total_net_amount`, `transaction_currency`, `items` (list) |
| `Sap.SalesOrders.SalesOrder.Item` | `sales_order`, `sales_order_item`, `material`, `production_plant`, `storage_location`, `requested_quantity`, `requested_quantity_unit`, `confd_deliv_qty_in_order_qty_unit`, `sd_process_status`, `sales_order_item_category`, `delivery_status` |

## Test fixtures

A test plug answers with SAP's own JSON: the entity under `"d"`, a collection under
`"d" => %{"results" => [...]}`, field names in SAP's spelling, dates as `"/Date(1767225600000)/"`.

```elixir
# a created or fetched order
%{"d" => %{"SalesOrder" => "12345", "PurchaseOrderByCustomer" => "PO-123",
           "to_Item" => %{"results" => [%{"SalesOrderItem" => "10", "Material" => "SKU-1"}]}}}

# a rejection (status 400)
%{"error" => %{"code" => "V1/801", "message" => %{"value" => "..."},
               "innererror" => %{"errordetails" => [%{"code" => "V1/382", "message" => "..."}]}}}
```

See the `sap-client-setup` skill for starting the client in a test.

## Rules

- Always set `purchase_order_by_customer` on a create.
- Never wrap `create/1` in a retry.
- Amounts and quantities come back as strings. Use `Decimal` for arithmetic, never floats.
