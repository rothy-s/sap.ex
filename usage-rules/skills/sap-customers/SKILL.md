---
name: sap-customers
description: "Use when reading SAP customers with `Sap.Customers`: a customer's name or blocks, sales area data (currency, payment terms, incoterms), partner functions (ship-to, bill-to, payer) or addresses."
---

# SAP customers

Service `API_BUSINESS_PARTNER`. Module `Sap.Customers`. Read-only.

## One customer

```elixir
alias Sap.Customers.Params

%Params.Get{customer: "100001", expand: [:sales_areas, :partner_functions]}
|> Sap.Customers.get()
|> MyApp.Sap.request()
#=> {:ok, %Sap.Customers.Customer{}}
```

`:expand` chooses what loads with the customer:

- `[]` (default): the customer only. `sales_areas` is `[]`.
- `[:sales_areas]`: each `Sap.Customers.SalesArea` (currency, payment terms, incoterms).
- `[:partner_functions]`: the sales areas, each with its `Sap.Customers.PartnerFunction` rows.

Partner functions belong to a sales area, not to the customer:

```elixir
ship_tos =
  for area <- customer.sales_areas,
      partner <- area.partner_functions,
      partner.partner_function == "WE",
      do: partner.bp_customer_number
```

A customer SAP does not have is `%Sap.Error{kind: :not_found}`.

## Several customers

```elixir
%Params.List{customers: ["100001", "100002"]}
|> Sap.Customers.list()
|> MyApp.Sap.request()
```

- Unknown numbers are absent from the result, not an error.
- The numbers become one OR filter. Chunk long lists (a few dozen per call).
- An empty list raises `ArgumentError`.

## Addresses

```elixir
%Params.Addresses.List{business_partner: "100001"}
|> Sap.Customers.list_addresses()
|> MyApp.Sap.request()
#=> {:ok, [%Sap.Customers.Address{}]}
```

One business partner per call. A customer and its business partner normally share a number.

## What comes back

Every field is a string or `nil` unless noted. Each struct also has `:raw`, the row as SAP sent it.

| Struct | Fields |
|---|---|
| `Sap.Customers.Customer` | `customer`, `name`, `account_group`, `order_block`, `delivery_block`, `billing_block`, `posting_blocked` (boolean), `marked_for_deletion` (boolean), `sales_areas` (list) |
| `Sap.Customers.SalesArea` | `customer`, `sales_organization`, `distribution_channel`, `division`, `currency`, `customer_payment_terms`, `incoterms_classification`, `incoterms_location`, `shipping_condition`, `delivery_priority`, `supplying_plant`, `customer_pricing_procedure`, `order_block`, `partner_functions` (list) |
| `Sap.Customers.PartnerFunction` | `customer`, `sales_organization`, `distribution_channel`, `division`, `partner_counter`, `partner_function`, `bp_customer_number`, `customer_partner_description`, `default_partner` (boolean) |
| `Sap.Customers.Address` | `business_partner`, `address_id`, `full_name`, `street_name`, `house_number`, `additional_street_prefix_name`, `additional_street_suffix_name`, `city_name`, `region`, `postal_code`, `country`, `validity_start_date` (`Date`), `validity_end_date` (`Date`) |

## Test fixtures

A test plug answers with SAP's own JSON: the entity under `"d"`, a collection under
`"d" => %{"results" => [...]}`, and field names in SAP's spelling.

```elixir
%{"d" => %{
  "Customer" => "100001",
  "CustomerName" => "Acme Shoes",
  "OrderIsBlockedForCustomer" => "",
  "to_CustomerSalesArea" => %{"results" => [
    %{"SalesOrganization" => "1000", "Currency" => "USD", "CustomerPaymentTerms" => "NT30",
      "IncotermsClassification" => "FOB",
      "to_PartnerFunction" => %{"results" => [
        %{"PartnerFunction" => "WE", "BPCustomerNumber" => "100002"}
      ]}}
  ]}
}}
```

An address row: `"BusinessPartner"`, `"AddressID"`, `"StreetName"`, `"HouseNumber"`, `"CityName"`,
`"Region"`, `"PostalCode"`, `"Country"`. See the `sap-client-setup` skill for starting the client
in a test.

## Rules

- `order_block`, `delivery_block` and `billing_block` are SAP reason codes; `nil` means not blocked.
- Do not expand on `list/1` with many customers: the payload grows with every customer.
