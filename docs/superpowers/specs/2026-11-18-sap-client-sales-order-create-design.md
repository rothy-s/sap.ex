# SAP client library: core, Sales Order create, Customer read

Date: 2026-11-18. Status: draft for approval.

## Intent

Rothy's has two in-app SAP (S/4HANA OData) clients: a large one in Panorama
(`lib/panorama/services/clients/sap`, 109 files) and a trimmed port of the same design in Conductor
(`lib/conductor/services/clients/sap`, 21 files). Several Elixir apps need SAP, so the client
becomes a standalone library, `sap`, in the same family as `joor` and `nri`.

The first consumer is Conductor, which will create Sales Orders and read Customers.

## Decided by Christopher

- **Conductor's client is the starting point.** It already has Sales Order create and little
  coupling to its app.
- **Everything is a struct.** Connection, inputs, outputs, batches and errors.
- **Retry policy belongs to the host application**, not the library.
- **Batches are worth modelling**, along with anything else from Panorama that earns its place.
- **The client follows the `Ecto.Repo` pattern.** A host defines a module with `use Sap.Client`,
  configures it under its own OTP app, and adds it to its supervision tree. One app can define
  several (for example `SapQA` and `SapProd`). The same module owns the CSRF process.
- **A stale CSRF token is refreshed and the request resent once**, by that supervised process.
- **Custom `ZZ1_*` fields are named struct fields.**
- **A SAP sandbox is available** for verifying fields and running integration tests.
- **Conductor is the first consumer**: it creates Sales Orders and reads Customers.

Everything below this line that is not in that list is a proposal (marked "my call" where it is a
real choice).

## Goals

1. A host app can create a Sales Order with line items in SAP using only structs.
2. The library has no configuration of its own: no `config :sap`, no OS env reads, no
   process-dictionary overrides. All configuration belongs to a host-defined client module, and
   one app can run several against different SAP systems.
3. A host app can read Customers.
4. The library looks and feels like `joor`: pure functions build an operation; one function does
   I/O.
5. Conductor can delete its in-app client and depend on this library with mechanical changes.

## Non-goals (this piece of work)

- Porting Panorama's other resources (purchase orders, deliveries, handling units, products, ...).
- Migrating Panorama. It converges later, resource by resource.
- OData V4, the Gateway catalogue/`$metadata` reader, change documents.
- Sales Order update/delete.
- Telemetry and request logging (neither `joor` nor `nri` has them; add later if wanted).

## Anti-goals

- The library retrying a write on its own. A timed-out create may have succeeded in SAP; replaying
  it can create a duplicate order.
- A free-form map as the way to set modelled SAP fields.
- Credentials visible in `inspect` output, logs or error messages.

## Approaches considered

1. **Extract Conductor's client and reshape it (chosen).** It is a small, tested port that already
   contains create. The reshaping is: global config becomes a host-defined client module, retries
   come out, tuples and maps become structs.
2. **Extract Panorama's client.** It covers far more of SAP, but has no Sales Order create and
   depends on Panorama's DB-backed config, TLS and override modules. Too much to untangle for a
   first release.
3. **Write fresh in joor's style, using the existing clients as reference only.** Cleanest result,
   but throws away tested CSRF, session and `$batch` code that encodes hard-won SAP behaviour.

## Design

### Public API

```elixir
# In the host app
defmodule Conductor.SapQA do
  use Sap.Client, otp_app: :conductor
end

# config/runtime.exs
config :conductor, Conductor.SapQA,
  base_url: "https://sap-qa.example.com",
  sap_client: "110",
  user: System.fetch_env!("SAP_QA_USER"),
  password: System.fetch_env!("SAP_QA_PASSWORD")

# application.ex
children = [Conductor.SapQA, Conductor.SapProd]

# A call
%Sap.SalesOrders.Params.Create{
  sales_order_type: "OR",
  sales_organization: "1000",
  distribution_channel: "10",
  organization_division: "00",
  sold_to_party: "100001",
  purchase_order_by_customer: "PO-123",
  items: [%Params.Items.Create{material: "SKU-1", requested_quantity: 2}]
}
|> Sap.SalesOrders.create()
|> Conductor.SapQA.request()
#=> {:ok, %Sap.SalesOrders.SalesOrder{sales_order: "0000012345", ...}}
#=> {:error, %Sap.Error{}}
```

- Resource functions (`Sap.SalesOrders.create/1`, `Sap.Customers.get/1`, ...) are pure and return
  a `%Sap.Operation{}`. They know nothing about which SAP system will run them.
- `MyClient.request(operation)` is the only function that does I/O for a single operation.
- `MyClient.request(batch)` runs a `%Sap.Batch{}` (see Batches).
- `MyClient.stream(operation, acc, reducer)` pages a collection by `$skip`.
- No bang variants (matches `joor` and `nri`; Conductor's `request!/2` is dropped). My call.
- Success returns the decoded struct or list directly, as Conductor does, not a response wrapper.
  My call: SAP has no rate-limit or envelope metadata worth carrying on every call.

### `Sap.Client`

`use Sap.Client, otp_app: :my_app` generates, on the host module:

| Function | Purpose |
|---|---|
| `child_spec/1`, `start_link/1` | So the module can be listed in a supervision tree. |
| `request/1`, `stream/3` | The I/O functions above. |
| `config/0` | The resolved configuration, as a `%Sap.Client.Config{}` struct. |
| `init/1` (optional callback, overridable) | Receives the config from the app environment and returns `{:ok, config}`, for values only known at start. Same idea as `Ecto.Repo.init/2`. |

Configuration is read once, at `start_link`, from `Application.get_env(otp_app, module)`, merged
with any options passed to `start_link` (which is how tests inject `req_options`), passed through
`init/1`, then validated into `%Sap.Client.Config{}`. A missing or malformed key stops the
process from starting, with a message naming the key.

| Key | Notes |
|---|---|
| `base_url` | Origin only. The library appends `/sap/opu/odata/sap/<service>`. Required. |
| `sap_client` | The SAP mandant, sent as the `sap-client` header. Required; no default (Conductor's `"110"` fallback is removed). |
| `user`, `password` | Basic auth. Required. |
| `receive_timeout` | Default 60_000 ms. |
| `csrf_refresh_interval` | How often tokens are refreshed; see the client process below. |
| `req_options` | Merged into the Req call. The test seam (`plug: {Req.Test, ...}`) and the place for TLS settings. |

`%Sap.Client.Config{}` derives `Inspect` without `password`.

A client must have been started once before any request, because that is when its configuration
is resolved and stored. See "If the process is down" below for what that means for reads and
writes.

The `use` macro stays thin: each generated function is a one-line delegate to a plain function
(`Sap.Client.request(module, operation)` and so on), so the logic is ordinary, testable code.

This replaces Conductor's `Sap.Config` module entirely.

### The client process (CSRF tokens and cookies)

Each started client module is one process (Conductor's `Session` GenServer, generalised),
registered under the module's name. State lives outside the process so callers never queue
behind it:

| State | Where | Why |
|---|---|---|
| `%Sap.Client.Config{}` | `:persistent_term`, keyed by the client module, written once at start | It never changes after boot. Reads are free, and it survives a restart of the client process. |
| CSRF session per SAP service (token + cookies) | A named ETS table owned by the process, `read_concurrency: true` | It changes. Callers read it directly; only the process writes it. |

Callers reach both only through `Sap.Client` functions, never the storage itself.

Because each client module has its own config entry, process and table, `SapQA` and `SapProd`
can never share a token or credentials.

**Request path.** Requests run in the caller's process. A GET reads the config and goes. A write
reads the config and the token from ETS and goes. The process is contacted only in the rare case
that the token is missing or SAP has rejected it.

**Keeping the token fresh.** The process owns the token's lifetime: it fetches on boot and
always refreshes.

- **On boot**, the process fetches a token for every SAP service the library can write to. Each
  resource module declares its service, so the list comes from the library, not from host config
  (my call). Today that is `API_SALES_ORDER_SRV`.
- The boot fetch runs right after `init` returns (`handle_continue`), so it does not hold up the
  host's supervision tree, and a SAP outage at boot does not stop the app from starting (my
  call). A failed fetch is tried again at the next refresh.
- **Always**, on a timer, the process refreshes every token, for as long as it runs. The interval
  is the config key `csrf_refresh_interval` (default 15 minutes, my call, to be set from the
  sandbox's session timeout). It cannot be switched off.
- Fallback: a write that finds no token (boot fetch still in flight or failed) asks the process,
  which elects one caller to fetch while concurrent callers wait for that result.
- Safety net: if SAP still answers a write with `403` and `x-csrf-token: Required`, it rejected
  the request before processing it. The process rotates the token (once per generation, however
  many callers hit it together) and the caller resends exactly once. This is the only automatic
  resend in the library.

**If the process is down.** Config is still readable, so GETs keep working during a restart.
Tokens are gone with the table; a write returns `{:error, %Sap.Error{kind: :not_started}}`
until the supervisor restarts the client, and the first write afterwards fetches a new token.
A client that has never been started has no config, so every call returns `:not_started`.

### Retries

The library performs **no retries**: Req runs with `retry: false`, and Conductor's hand-rolled
GET retry loop and the `:retries` option are removed. The CSRF resend above is a handshake, not a
retry policy.

The client's `req_options` is the host's hook for read retries: a host may pass Req's
`retry: :safe_transient` to retry GETs. For any non-GET (creates and `$batch`) the library forces
`retry: false` after merging `req_options`, so a host cannot switch on write replays by accident.
My call. `stream/3` relies on the same hook; without it, a failed page fails the stream.

To let hosts write their own policy, `Sap.Error` carries enough to decide (see Errors), and the
docs state plainly that a `:timeout`, `:transport` or 5xx on a write means "outcome unknown".

### Operations and OData

Ported from Conductor with the namespace `Sap.*`:

- `Sap.Operation`: the inert request struct. The `opts` keyword list is replaced by struct fields
  (`receive_timeout`, `page_size`, `max_pages`, `truncation`). The `:retries` and `retry` concepts
  are removed.
- `Sap.Odata.Query`, `Filterable`, `Encode`, `Decode`, `Date`: unchanged in behaviour.
- `Sap.HTTP` (was `HttpClient`) and `Sap.HTTP.Response`: the only modules that call Req. URL
  building, headers, CSRF, error classification, HTML-login detection, envelope unwrap.

Fixes made during the port:

- An unrecognised collection envelope returns `{:error, %Sap.Error{kind: :decode}}`, not `[]`.
- The CSRF probe sends its own headers, not the operation's.
- `Encode.number/1` accepts `Decimal`; a float raises `ArgumentError` with a clear message.
- Helpers with no caller after the port are dropped.

### Batches

Conductor's V2 `$batch` multipart encoder/decoder is kept, with structs in place of tuples:

```elixir
%Sap.Batch{
  service: "API_SALES_ORDER_SRV",
  parts: [
    get_operation,
    %Sap.Batch.Changeset{operations: [create_op_1, create_op_2]}
  ]
}
|> Conductor.SapQA.request()
#=> {:ok, %Sap.Batch.Response{parts: [%Sap.Batch.Result{...}, %Sap.Batch.Changeset.Result{results: [...]}]}}
```

- `%Sap.Batch.Result{status, headers, data, error}`: `data` is decoded with the originating
  operation's decoder on 2xx; `error` is a `%Sap.Error{}` otherwise. (Today parts come back as raw
  `{:http, status, headers, body}`.)
- A failed part is **not** a failed call. `{:error, _}` means the batch request itself failed.
  `Sap.Batch.Response.ok?/1` answers "did every part succeed".
- A changeset is atomic in SAP: all of its operations commit or none do. When one fails, SAP
  returns a single error in place of the whole changeset, so `%Sap.Batch.Changeset.Result{}` has
  `results: [...]` on success, or `error: %Sap.Error{}` and `results: []` on failure. My call; to
  be confirmed against a real failed-changeset response from the tenant.

### Sales Orders

Service `API_SALES_ORDER_SRV` (OData V2). Module `Sap.SalesOrders` with pure builders:

- `create/1`: `POST /A_SalesOrder`, deep insert. `receive_timeout` 120_000.
- `get/1`, `list/1`, `list_items/1`: ported as they are.

**Create input**, all structs, no `attrs` map. Partners, pricing elements and texts are modelled
in this release, at header and item level, so that callers (people and agents) work with typed
data throughout:

| Struct | Fields | SAP navigation |
|---|---|---|
| `Params.Create` | required: `sales_order_type`, `sales_organization`, `distribution_channel`, `organization_division`, `sold_to_party`; optional: `purchase_order_by_customer`, `requested_delivery_date`, `transaction_currency`, `customer_payment_terms`, `incoterms_classification`, `start_ship_date`, `end_ship_date`; lists: `items` (at least one), `partners`, `pricing_elements`, `texts` | `A_SalesOrder` |
| `Params.Items.Create` | required: `material`, `requested_quantity`; optional: `sales_order_item`, `requested_quantity_unit`, `production_plant`, `storage_location`; lists: `pricing_elements`, `texts` | `to_Item` |
| `Params.Partners.Create` | `partner_function`, `customer` | `to_Partner` |
| `Params.PricingElements.Create` | `condition_type`, `condition_rate_value`, `condition_currency` | `to_PricingElement` |
| `Params.Texts.Create` | `language`, `long_text_id`, `long_text` | `to_Text` |

The exact optional field list is the builder's to confirm against the sandbox's `$metadata`; the
set above is the starting point. Adding a SAP field means adding a struct field.

**Custom fields** are named struct fields with readable names, mapped to their `ZZ1_*` wire names
inside the library. The two sales-order header fields found in Panorama are included:
`start_ship_date` (`ZZ1_StartShipDate_SDH`) and `end_ship_date` (`ZZ1_EndShipDate_SDH`). The same
fields are decoded onto `%SalesOrder{}`.

- Validation is `@enforce_keys` plus a non-empty `items` guard that raises `ArgumentError`. No
  other client-side validation; SAP is the authority (joor's convention).
- Quantities and amounts are `Decimal` or integer in, strings out on the wire. Dates are `Date` in.
- Output is `%SalesOrder{}` with `items: [%SalesOrder.Item{}]`, each keeping `raw`.
- Warnings SAP may return on a successful save (the `sap-message` header) are not surfaced in
  this release. Adding a `messages` field to `%SalesOrder{}` later is not a breaking change. My
  call.

### Customers

Service `API_BUSINESS_PARTNER` (OData V2), entity `A_Customer`. Ported from Panorama's `Customer`
resource into `Sap.Customers`, read-only:

- `get/1`: one customer by number; a missing customer is `%Sap.Error{kind: :not_found}`.
- `list/1`: customers for a list of numbers (an OR filter; chunking a long list is the caller's
  job).

Conductor needs more than Panorama's `number` and `name`, so the customer is modelled with its
related entities, each a typed struct:

| Struct | SAP entity | Holds |
|---|---|---|
| `Sap.Customers.Customer` | `A_Customer` | number, name, account group, blocks |
| `Sap.Customers.SalesArea` | `A_CustomerSalesArea` (`to_CustomerSalesArea`) | sales organization, distribution channel, division, currency, payment terms, incoterms |
| `Sap.Customers.PartnerFunction` | `A_CustSalesPartnerFunc` (`to_PartnerFunction`) | partner function, partner customer number (sold-to, ship-to, bill-to, payer) |
| `Sap.Customers.Address` | `A_BusinessPartnerAddress` | street, city, region, postal code, country (ported from Panorama's `business_partner_address`) |

`get/1` takes an `expand` list of typed atoms (`:sales_areas`, `:partner_functions`) so the caller
chooses how much to load; addresses are read with `Sap.Customers.list_addresses/1`. Field lists
are confirmed against the sandbox's `$metadata`. Every struct keeps `raw`. Panorama's overridable entity path is
dropped unless the sandbox shows it is needed.

### Errors

`%Sap.Error{}` (a `defexception`), ported from Conductor with additions:

- `kind`: `:transport | :timeout | :http | :not_found | :auth | :html_session | :decode | :csrf |
  :truncated`. `:not_found` (404) comes from Panorama. `:not_configured` is replaced by `:not_started`: a
  client with bad configuration never starts.
- `code`: SAP's `error.code` (for example `V1/801`). New.
- `details`: `[%Sap.Error.Detail{code, message, severity, target}]` from `errordetails`. New.
- `status`, `message`, `service`, `method`, `url`, `body`, `reason`: as today.
- `message/1` truncates the body, so order data does not leak into logs.

### Testing

- `Req.Test` through the client's `req_options`; no network in the default suite.
- Tests define their own client modules with `use Sap.Client` and start them per test with
  `start_supervised!({TestClient, req_options: [plug: ...]})`. Hosts test the same way.
- `test/support/api_case.ex` in nri's style: `expect/1`, `fixture/1`.
- Operation builders are tested as plain structs; HTTP behaviour (CSRF fetch, cookie round-trip,
  403 replay, error parsing, batch encode/decode) through stubs.
- New coverage Conductor lacks: failed create with a real SAP error body, cookie round-trip on
  create, a 201 with expanded `to_Item`.
- Integration tests against the SAP sandbox tagged `:integration`, excluded by default,
  credentials from a gitignored `config/test.override.exs`.

### Tooling

nri's set: Elixir `~> 1.20`, `req ~> 0.7.4`, `decimal`, `credo --strict`, `dialyxir`, `ex_doc`,
`plug` (test only), the built-in `JSON` module. CI: format, compile with warnings as errors,
credo, tests, dialyzer, docs. A README and a `CONTRIBUTING.md` of conventions, as in `joor`.

## Order of work

1. Project setup and tooling; `git init`.
2. `Sap.Error`, `Sap.Operation`, OData modules (pure, no I/O).
3. `Sap.Client` (`use` macro, config, process), `Sap.HTTP`, `request/1` for GETs.
4. `Sap.Customers.get/1` and `list/1`: the first end-to-end slice, read-only.
5. Writes: CSRF fetch, cookies, stale-token resend.
6. `Sap.SalesOrders.create/1` with its structs, then `get`, `list`, `list_items`.
7. `Sap.Batch` and `stream/3`.
8. Docs and integration tests against the sandbox.

Follow-up, outside this repo: Conductor swaps its in-app client for the library.

## Left to the builder

- File layout under `lib/sap/`, private helper names, test file organisation.
- The exact optional field lists, checked against `$metadata`.
- Wire formats per field (`/Date(ms)/` versus ISO), following Conductor's existing behaviour.

## Open questions

None. No custom fields beyond start and end ship date are known today; more are added as named
struct fields when they come up.

## As built (2026-11-18)

Where the code differs from, or settles, the text above:

- **Field names are not yet checked against the sandbox.** No sandbox credentials were used during
  the build. `test/integration/sandbox_test.exs` checks every field name the library reads or
  writes against each service's `$metadata`; run it before the first real use.
- **Partner functions sit under sales areas.** In SAP they belong to `A_CustomerSalesArea`, so
  `%Customer{}` has `sales_areas`, and each `%SalesArea{}` has `partner_functions`.
- **Addresses** are read with `Sap.Customers.list_addresses/1` (one business partner per call).
- **`extra_filter` was dropped** from the list params. It was a free-form OData string.
- **The failed-changeset struct** is `Sap.Batch.Changeset.Result`.
- **`stream/3` at `max_pages`** returns `{:error, %Sap.Error{kind: :truncated}}`. Conductor logged
  and returned partial results.
- **Tests use plain plug functions**, not `Req.Test` stubs, because the client process makes
  requests of its own (the boot fetch) from outside the test process.
- **Item-level partners and schedule lines are not modelled.**
- **`csrf_refresh_interval` defaults to 15 minutes**, not yet checked against the sandbox's
  session timeout.

### HTTP adapter (added 2026-11-19)

Requests go through the `Sap.HTTP.Adapter` behaviour (one callback, `request/2`, taking a
`%Sap.HTTP.Request{}` and returning a `%Sap.HTTP.Response{}`), so a host can swap the HTTP client.
`Sap.HTTP.ReqAdapter` is the default and the only module that calls Req. The client key
`:adapter` takes a module or `{module, options}`; `:req_options` remains the Req adapter's
options. CSRF handling, classification and decoding stay in `Sap.HTTP`, above the adapter. The
module that unwraps OData envelopes was renamed from `Sap.HTTP.Response` to `Sap.HTTP.Envelope`.

### Config on orderly shutdown (changed 2026-11-19)

The client process traps exits and erases its `:persistent_term` config when it stops for an
orderly reason (`:normal`, `:shutdown`, `{:shutdown, _}`), so a stopped client returns
`:not_started` for reads as well as writes. After a crash or a brutal kill the config stays, so
reads keep working until the supervisor restarts the process. This replaces "If the process is
down" above for the orderly case.

### Field names checked against QA `$metadata` (2026-11-19)

Every SAP field and navigation name the library reads or writes was compared with the
`$metadata` of `API_SALES_ORDER_SRV` and `API_BUSINESS_PARTNER` from the QA system. All matched
except two item fields carried over from Conductor, `ItemBillingQuantity` and `CumulReqdDelivQty`,
which do not exist on `A_SalesOrderItem` and were removed. Two customer name fallbacks that exist
only on `A_BusinessPartner` were also dropped. This replaces the first "As built" note above.
