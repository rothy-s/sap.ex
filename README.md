# Sap

An Elixir client for SAP S/4HANA OData services, shared by Rothy's Elixir applications.

It currently covers:

- **Sales orders** (`API_SALES_ORDER_SRV`): create, get, list, list items
- **Customers** (`API_BUSINESS_PARTNER`): get and list customers with their sales areas and
  partner functions, and list addresses
- **Batches**: several operations in one OData `$batch` request

Everything in and out is a typed struct.

## Installation

```elixir
def deps do
  [
    {:sap, github: "rothy-s/sap.ex"}
  ]
end
```

## Setup

Define a client module for each SAP system your app talks to. It works like an `Ecto.Repo`.

```elixir
defmodule MyApp.SapQA do
  use Sap.Client, otp_app: :my_app
end

defmodule MyApp.SapProd do
  use Sap.Client, otp_app: :my_app
end
```

Configure each one under your own app:

```elixir
# config/runtime.exs
config :my_app, MyApp.SapQA,
  base_url: "https://sap-qa.example.com",
  sap_client: "110",
  user: System.fetch_env!("SAP_QA_USER"),
  password: System.fetch_env!("SAP_QA_PASSWORD")
```

Add them to your supervision tree:

```elixir
children = [MyApp.SapQA, MyApp.SapProd]
```

Each client is one process. It validates its configuration on boot, and keeps a CSRF token ready
for writes: it fetches one on boot and refreshes it on a timer. Requests run in the calling
process. See `Sap.Client` for every option.

The refresh interval defaults to 15 minutes. Set it below your SAP system's session timeout:

```elixir
config :my_app, MyApp.SapQA, csrf_refresh_interval: :timer.minutes(10)
```

## Creating a sales order

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
|> MyApp.SapQA.request()
#=> {:ok, %Sap.SalesOrders.SalesOrder{sales_order: "12345", items: [...]}}
```

## Reading a customer

```elixir
%Sap.Customers.Params.Get{customer: "100001", expand: [:sales_areas, :partner_functions]}
|> Sap.Customers.get()
|> MyApp.SapQA.request()
#=> {:ok, %Sap.Customers.Customer{customer: "100001", sales_areas: [%Sap.Customers.SalesArea{}]}}
```

## Errors

Every call returns `{:ok, result}` or `{:error, %Sap.Error{}}`. Match on `:kind`:

```elixir
case MyApp.SapQA.request(operation) do
  {:ok, order} -> order
  {:error, %Sap.Error{kind: :not_found}} -> nil
  {:error, %Sap.Error{kind: :http, code: code, message: message, details: details}} -> ...
end
```

`:code`, `:message` and `:details` come from SAP's error body.

## Retries are your application's job

The library does not retry. This matters most for writes: SAP has no idempotency key, so when a
create fails with `:timeout`, `:transport` or a 5xx, SAP may still have created the order. Look it
up (for example by `purchase_order_by_customer`) before sending it again.

To retry reads at the HTTP level, pass Req's option through the client:

```elixir
config :my_app, MyApp.SapQA, req_options: [retry: :safe_transient]
```

Retries stay off for writes whatever `:req_options` says.

The one automatic resend is part of SAP's CSRF handshake: when SAP rejects a write because its
token is stale, it has not processed the request, so the client fetches a new token and sends the
request once more.

## Using a different HTTP client

Requests are sent by an adapter. The default, `Sap.HTTP.ReqAdapter`, uses Req and takes its
options from `:req_options`. To use your own HTTP client, implement `Sap.HTTP.Adapter` (one
callback, `request/2`) and name it in the client's configuration:

```elixir
config :my_app, MyApp.SapQA, adapter: {MyApp.SapAdapter, pool: :sap}
```

The library still builds every request (URL, authentication, CSRF token, body) and interprets
every response, so behaviour is the same with any adapter. An adapter must never retry a request
that is not a `GET`; see `Sap.HTTP.Adapter` for the full contract.

## Testing your application

Start the client in your test with a plug in place of the network:

```elixir
plug = fn conn ->
  conn
  |> Plug.Conn.put_resp_header("x-csrf-token", "test-token")
  |> Plug.Conn.put_resp_content_type("application/json")
  |> Plug.Conn.send_resp(200, ~s({"d": {"Customer": "100001"}}))
end

start_supervised!({MyApp.SapQA, req_options: [plug: plug]})
```

The plug also receives the CSRF token fetch the client makes on boot, from the client's own
process. A plain function plug works from any process; a `Req.Test` stub needs
`Req.Test.set_req_test_to_shared/1`.

## Developing

```sh
mix test                              # no network
mix test --cover                      # fails below 90% coverage
mix credo --strict
mix deps.audit                        # known vulnerabilities in dependencies
mix dialyzer
mix test --only integration           # reads against the SAP sandbox
mix test --only integration_write     # creates a real sales order in the sandbox
```

Integration tests read credentials and master data from the gitignored
`config/test.override.exs`; see `test/integration/sandbox_test.exs`.

Adding a resource: write a module of pure functions that return `Sap.Operation` structs, with
params structs under `Params` and response structs beside it. `Sap.Customers` is the smallest
example. If the resource has writes, add its service to `csrf_services/0` in
`lib/sap/client/server.ex` so its token is fetched on boot.
