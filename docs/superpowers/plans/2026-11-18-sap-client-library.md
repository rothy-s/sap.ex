# SAP Client Library Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** A standalone Elixir library, `sap`, that lets a host app create Sales Orders and read Customers in SAP S/4HANA through typed structs.

**Architecture:** Pure resource functions build an inert `%Sap.Operation{}`. A host-defined module (`use Sap.Client, otp_app: :my_app`) runs it. Each client module is one supervised process that validates config at boot (stored in `:persistent_term`) and keeps CSRF tokens fresh in an ETS table; requests run in the caller's process.

**Tech Stack:** Elixir ~> 1.20, Req ~> 0.7.4, Decimal, built-in `JSON`, credo, dialyxir, ex_doc. Tests use plain plug functions through `req_options`.

**Spec:** `docs/superpowers/specs/2026-11-18-sap-client-sales-order-create-design.md`

**Source being extracted:** `../conductor/lib/conductor/services/clients/sap` (read-only). Customers come from `../panorama/lib/panorama/services/clients/sap/{customer,business_partner_address}` (read-only).

## Global Constraints

- No `config :sap`, no `System.get_env`, no process-dictionary overrides in `lib/`.
- No retries in the library. Req runs with `retry: false`; for non-GET requests `retry: false` is forced after merging the host's `req_options`.
- The only automatic resend: one replay after `403` + `x-csrf-token: Required`.
- No free-form maps for modelled SAP fields. No `attrs`.
- No bang API functions. Success returns the decoded struct or list; failure returns `{:error, %Sap.Error{}}`.
- `password` never appears in `inspect` output or error messages.
- OData V2 only. URL is `<base_url origin>/sap/opu/odata/sap/<service><path>`.
- One module per file. Every public module has a `@moduledoc`; every public function a `@doc` and `@spec`.
- `mix format --check-formatted`, `mix compile --warnings-as-errors`, `mix credo --strict`, `mix test` all pass at the end of every task.

## Review Focus

1. **A write times out after SAP accepted it.** Expect `{:error, %Sap.Error{kind: :timeout}}` and exactly one POST on the wire, even when the host set `req_options: [retry: :transient]`. Pinned in Task 5.
2. **SAP is down when the app boots.** Expect the client to start, reads to fail with `:transport`, and the first write after SAP returns to fetch a token on demand. Pinned in Task 5.
3. **SAP answers 200 with an HTML login page.** Expect `:html_session`, never an empty list. Pinned in Task 4.
4. **A collection response in an unrecognised envelope.** Expect `:decode`, never `[]`. Pinned in Task 4.
5. **A changeset fails inside a `$batch`.** Expect `{:ok, response}` with that changeset's `error` set and `results: []`, and `Sap.Batch.Response.ok?/1` false. Pinned in Task 8.

---

## File map

```
lib/sap.ex                                 moduledoc: overview and example
lib/sap/client.ex                          `use` macro; request/2, stream/4, config/1, session lookup
lib/sap/client/config.ex                   %Config{} + new!/1 validation
lib/sap/client/server.ex                   GenServer: boot, persistent_term, ETS, token refresh, rotation
lib/sap/http.ex                            only module calling Req: run/3, run_batch/3, fetch_csrf/2
lib/sap/http/response.ex                   HTML gate, envelope unwrap, decoder
lib/sap/operation.ex                       inert request struct
lib/sap/error.ex, lib/sap/error/detail.ex  exception + errordetails rows
lib/sap/odata/{query,filterable,encode,decode,date}.ex
lib/sap/batch.ex                           %Batch{} + multipart encode/decode
lib/sap/batch/{changeset,response,result}.ex, batch/changeset/result.ex
lib/sap/customers/customers.ex                       get/1, list/1, list_addresses/1
lib/sap/customers/{customer,sales_area,partner_function,address}.ex
lib/sap/customers/params/{get,list}.ex, params/addresses/list.ex
lib/sap/sales_orders/sales_orders.ex                    create/1, get/1, list/1, list_items/1
lib/sap/sales_orders/sales_order.ex, sales_order/item.ex
lib/sap/sales_orders/params/{get,list}.ex, params/items/list.ex
lib/sap/sales_orders/params/create.ex
lib/sap/sales_orders/params/{items,partners,pricing_elements,texts}/create.ex
test/support/api_case.ex                   test client modules, plug helper, fixtures
```

---

### Task 1: Project setup

**Files:** `mix.exs`, `.formatter.exs`, `.tool-versions`, `.credo.exs`, `.gitignore`, `.github/workflows/ci.yml`, `README.md`

- [ ] `git init`; `.tool-versions`: `elixir 1.20.1-otp-29`, `erlang 29.0.2`.
- [ ] `mix.exs`: deps `req ~> 0.7.4`, `decimal ~> 2.0 or ~> 3.0`, `plug ~> 1.16` (test), `credo ~> 1.7`, `dialyxir ~> 1.4`, `ex_doc ~> 0.34` (dev/test, `runtime: false`); `elixirc_paths(:test)` adds `test/support`; no `mod:` in `application/0`.
- [ ] CI steps as in `nri`: `deps.get --check-locked`, `format --check-formatted`, `compile --warnings-as-errors`, `credo --strict`, `test --warnings-as-errors`, `docs --warnings-as-errors`, dialyzer job.
- [ ] Verify: `mix deps.get && mix compile --warnings-as-errors`. Commit.

### Task 2: Pure core — `Sap.Error`, `Sap.Operation`, OData modules

**Files:** `lib/sap/error.ex`, `lib/sap/error/detail.ex`, `lib/sap/operation.ex`, `lib/sap/odata/*.ex`; tests under `test/sap/`.

**Produces:**
- `%Sap.Error{kind, service, method, url, status, code, message, details, body, reason}`; `Sap.Error.new(kind, fields)`; kinds `:not_started | :transport | :timeout | :http | :not_found | :auth | :html_session | :decode | :csrf | :truncated`.
- `%Sap.Error.Detail{code, message, severity, target}`.
- `%Sap.Operation{service, method, path, query, body, headers, shape, decoder, csrf, parser, receive_timeout, truncation, page_size, max_pages}`; `csrf?/1`, `content_type/1`, `encoded_body/1`, `params/1`. No `opts`, no `retryable?/1`.
- `Sap.Odata.Query`, `Filterable`, `Encode`, `Decode`, `Date`: Conductor's modules renamed. `Encode.number/1` accepts integer, binary and `Decimal`; a float raises `ArgumentError`.

- [ ] Port the pure modules and their doctests by copy + rename; delete helpers with no caller.
- [ ] Tests: `Error.new/2` fills `code`, `message` and `details` from a V2 error body with `errordetails` at `error.errordetails` and at `error.innererror.errordetails`; `Exception.message/1` never contains more than 800 characters of body; `Encode.number(1.5)` raises `ArgumentError`; `Encode.number(Decimal.new("1.50"))` is `"1.50"`.
- [ ] Verify, commit.

### Task 3: `Sap.Client` — macro, config, process (no HTTP yet)

**Files:** `lib/sap/client.ex`, `lib/sap/client/config.ex`, `lib/sap/client/server.ex`, `test/support/api_case.ex`, `test/sap/client_test.exs`

**Produces:**
- `%Sap.Client.Config{base_url, sap_client, user, password, receive_timeout: 60_000, csrf_refresh_interval: 900_000, csrf_timeout: 15_000, req_options: []}`; `Config.new!(keyword) :: t()` raising `ArgumentError` naming the bad key; `base_url` reduced to its origin; `Inspect` derived without `:password`.
- `use Sap.Client, otp_app: atom` generating `child_spec/1`, `start_link/1`, `config/0`, `request/1`, `stream/3`, overridable `init/1 :: {:ok, keyword}`. Each is a one-line delegate.
- `Sap.Client.config(module) :: {:ok, Config.t()} | {:error, %Sap.Error{kind: :not_started}}` reading `:persistent_term` key `{Sap.Client, module}`.
- `Sap.Client.session(module, service)` and `Sap.Client.rotate(module, service, generation)` `:: {:ok, %{token, cookies, generation}} | {:error, Sap.Error.t()}`.
- Server: registered as the client module; ETS table named `Module.concat(module, "CsrfSessions")`, `:protected`, `read_concurrency: true`. Config resolution order: app env, then `start_link` opts, then `init/1`.

- [ ] Tests: missing `:password` stops `start_link` with a message containing `:password`; `config/0` before start is `:not_started`; config is still readable after the process is killed; `inspect(config)` does not contain the password; two client modules hold different configs; `init/1` override is applied.
- [ ] Verify, commit.

### Task 4: `Sap.HTTP` reads + `Sap.Customers`

**Files:** `lib/sap/http.ex`, `lib/sap/http/response.ex`, `lib/sap/customers.ex`, `lib/sap/customers/**`, tests.

**Produces:**
- `Sap.HTTP.run(module, Config.t(), Operation.t()) :: {:ok, term} | {:error, Sap.Error.t()}`. Query string built with `Sap.Odata.Query.encode/1` onto the URL (spaces as `%20`).
- `Sap.Client.request(module, operation)`.
- `Sap.Customers.get(%Params.Get{customer, expand: [:sales_areas | :partner_functions]})`, `list(%Params.List{customers: [..]})`, `list_addresses(%Params.Addresses.List{business_partner})`. Service `API_BUSINESS_PARTNER`; entities `/A_Customer`, `/A_BusinessPartnerAddress`; navigations `to_CustomerSalesArea` and `to_CustomerSalesArea/to_PartnerFunction`.
- Structs `Customer`, `SalesArea`, `PartnerFunction`, `Address`, each with `from_odata/1` and `raw`.

- [ ] Tests (HTTP, through a plug): basic auth and `sap-client` headers are sent; 404 is `:not_found`; 401 is `:auth`; 500 is `:http` with one request on the wire; transport timeout is `:timeout`; HTML login page with status 200 is `:html_session`; unrecognised collection envelope is `:decode`; `d.__next` is `:truncated`; a host `req_options: [retry: :safe_transient]` does retry a GET.
- [ ] Tests (builders, no HTTP): `get/1` path is `/A_Customer('100001')`; `expand: [:sales_areas, :partner_functions]` renders `$expand=to_CustomerSalesArea,to_CustomerSalesArea/to_PartnerFunction`; `list/1` with `[]` raises `ArgumentError`; decoding a row with expanded sales areas yields nested structs.
- [ ] Verify, commit.

### Task 5: Writes — CSRF fetch on boot, refresh, rotation

**Files:** `lib/sap/client/server.ex`, `lib/sap/http.ex`, `test/sap/csrf_test.exs`

**Produces:**
- `Sap.HTTP.fetch_csrf(Config.t(), service) :: {:ok, %{token, cookies}} | {:error, Sap.Error.t()}`: `GET <service root>/?$format=json` with `x-csrf-token: Fetch`, its own headers only.
- `Sap.Client.Server.csrf_services/0`: services fetched on boot, taken from resource modules (`[Sap.SalesOrders.service()]`).
- Server behaviour: boot fetch in `handle_continue`; refresh of every known service each `csrf_refresh_interval`; fetches run in monitored helper processes so the server never blocks; callers that miss wait for the in-flight fetch.

- [ ] Tests: token and cookies fetched on boot are sent on the first POST with no extra fetch; a `403 Required` causes one rotation and one resend; a second `Required` returns `:csrf`; ten concurrent writers after a miss cause one fetch; the refresh timer replaces the token (interval set to 20 ms in the test); boot with SAP unreachable still starts and the next write fetches on demand; a POST that times out is sent once even with `req_options: [retry: :transient]`; a write to a stopped client is `:not_started`.
- [ ] Verify, commit.

### Task 6: `Sap.SalesOrders.create/1`

**Files:** `lib/sap/sales_orders.ex`, `lib/sap/sales_orders/**`, `test/sap/sales_orders_create_test.exs`

**Produces:** the structs in the spec's Create table, each with `to_odata/1`; `SalesOrder.from_odata/1` and `SalesOrder.Item.from_odata/1`; `Sap.SalesOrders.service/0` = `"API_SALES_ORDER_SRV"`. `start_ship_date` ↔ `ZZ1_StartShipDate_SDH`, `end_ship_date` ↔ `ZZ1_EndShipDate_SDH`. Navigations `to_Item`, `to_Partner`, `to_PricingElement`, `to_Text`.

- [ ] Tests: minimal create body has the five organisational fields and `to_Item`; nil optionals are omitted; empty nested lists are omitted; partners, pricing elements and texts render under their navigations at header and item level; dates render as `/Date(ms)/`; `Decimal` quantity renders as a string; `items: []` raises `ArgumentError`; missing enforced key raises; end to end through a plug returns `%SalesOrder{sales_order: "12345"}` with items; a 400 with a SAP error body returns `:http` with `code` and `details` set.
- [ ] Verify, commit.

### Task 7: Sales Order reads and `stream/3`

**Produces:** `Sap.SalesOrders.get/1`, `list/1`, `list_items/1` (ported); `Sap.Client.stream(module, operation, acc, reducer)`. Reaching `max_pages` returns `{:error, %Sap.Error{kind: :truncated}}`.

- [ ] Tests: builders render the same paths and filters as Conductor; `stream` pages until a short page; a failed page returns the error; `max_pages` returns `:truncated`.
- [ ] Verify, commit.

### Task 8: `Sap.Batch`

**Produces:** `%Sap.Batch{service, parts}`, `%Sap.Batch.Changeset{operations}`, `%Sap.Batch.Response{parts}` with `ok?/1`, `%Sap.Batch.Result{status, headers, data, error}`, `%Sap.Batch.Changeset.Result{results, error}`. `request/1` accepts a `%Sap.Batch{}`.

- [ ] Tests: encode/decode round trip (ported); results are decoded with the originating operation's decoder; a failed part is a `Result` with `error`; a failed changeset is `Changeset.Result{error: %Sap.Error{}, results: []}` and `ok?/1` is false; part count mismatch is `:decode`; the batch POST carries the CSRF token.
- [ ] Verify, commit.

### Task 9: Docs and integration tests

- [ ] README: install, define a client, supervise, create an order, read a customer, errors, testing in a host app, what the host owns (retries).
- [ ] `test/integration/*_test.exs` tagged `:integration`, excluded by default, config from gitignored `config/test.override.exs`: read a customer, read `$metadata`-backed field names for every struct, create one order.
- [ ] `mix docs --warnings-as-errors`, `mix dialyzer`. Commit.
