# Rules for working with Sap

`sap` is a client for SAP S/4HANA OData services. Resource modules build an inert
`%Sap.Operation{}`; a client module you define runs it.

## The shape of every call

```elixir
%Sap.Customers.Params.Get{customer: "100001"}
|> Sap.Customers.get()
|> MyApp.Sap.request()
#=> {:ok, %Sap.Customers.Customer{}} | {:error, %Sap.Error{}}
```

- Build params as structs. Never pass maps or keyword lists to resource functions.
- Run operations through the host app's client module (`MyApp.Sap.request/1`), never through
  `Sap.Client.request/2` directly.
- There are no bang functions. Match on `{:ok, _}` and `{:error, %Sap.Error{kind: kind}}`.

## The client

- Define one module per SAP system: `use Sap.Client, otp_app: :my_app`.
- Configure it under the host app (`config :my_app, MyApp.Sap, base_url: ..., sap_client: ...,
  user: ..., password: ...`). There is no `config :sap`.
- Add the module to the supervision tree. A client that was never started, or has been stopped,
  returns `%Sap.Error{kind: :not_started}` for every call.
- Do not start one client module twice, and do not share one module between SAP systems.
- The client keeps a CSRF token fresh for writes. `:csrf_refresh_interval` (milliseconds, default
  15 minutes) sets how often; keep it below the SAP system's session timeout.

## Writes and retries

- The library never retries. Do not wrap a write in a retry loop.
- When a write fails with `:timeout`, `:transport`, or `:http` with a 5xx status, the outcome is
  **unknown**: SAP may have created the document. Look it up before sending it again (for a sales
  order, by `purchase_order_by_customer`).
- Always set `purchase_order_by_customer` on a created sales order so it can be found again.
- Read retries are a host decision: `req_options: [retry: :safe_transient]` on the client.

## Values

- Quantities and amounts in: integer, `Decimal` or decimal string. Floats raise `ArgumentError`.
- Quantities and amounts out: strings, exactly as SAP sent them. Build a `Decimal` for arithmetic.
- Dates in and out: `Date` structs.
- Every response struct keeps the original row in `:raw`.

## HTTP adapter

- Requests go through a `Sap.HTTP.Adapter`. The default is `Sap.HTTP.ReqAdapter`, configured
  with the client's `:req_options`.
- A host can set `adapter: MyAdapter` or `adapter: {MyAdapter, options}` on the client. With a
  custom adapter, `:req_options` and test plugs have no effect.
- A custom adapter must return every HTTP response as `{:ok, %Sap.HTTP.Response{}}`, return
  `{:error, :timeout}` on a receive timeout, and never retry a request that is not a `GET`.

## Batches

- A failed part of a `Sap.Batch` is reported in that part, not as `{:error, _}`. Check
  `Sap.Batch.Response.ok?/1`.
- Put writes that must succeed together in a `Sap.Batch.Changeset`. Never put reads in one.

## Testing a host app

- Start the client in the test with a plug: `start_supervised!({MyApp.Sap, req_options: [plug: fun]})`.
- The plug also receives the CSRF token fetch the client makes on boot, from the client's own
  process. Answer it with an `x-csrf-token` response header. Use a plain function plug, or
  `Req.Test.set_req_test_to_shared/1` with a `Req.Test` stub.
