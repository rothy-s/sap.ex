# Sap: guide for agents

`sap` is an Elixir client library for SAP S/4HANA OData services, used by several Rothy's apps
(Conductor first, Panorama later). Read `README.md` for usage and
`docs/superpowers/specs/2026-11-18-sap-client-sales-order-create-design.md` for the design and
its reasons.

## Before you finish any change

All of these must pass; CI runs the same commands.

```sh
mix format --check-formatted
mix compile --warnings-as-errors
mix credo --strict
mix test --cover --warnings-as-errors   # fails below 90% coverage
mix deps.audit
mix dialyzer
mix docs --warnings-as-errors
```

## Conventions

- **Structs everywhere.** Params in, structs out. No free-form maps or keyword lists for SAP data.
  A new SAP field is a new struct field. Custom `ZZ1_*` fields get readable names.
- **Resource functions are pure.** They take a params struct and return a `%Sap.Operation{}`.
- **HTTP goes through `Sap.HTTP.Adapter`.** `Sap.HTTP` builds each `%Sap.HTTP.Request{}` and
  interprets each `%Sap.HTTP.Response{}`; only `Sap.HTTP.ReqAdapter` calls Req. Keep CSRF
  handling, error classification and decoding out of adapters so every adapter behaves the same.
- **The library never retries.** Writes are sent once. The only automatic resend is the CSRF
  handshake in `Sap.HTTP`. Do not add retries, and do not weaken the rule in
  `Sap.HTTP.ReqAdapter` that forces `retry: false` on non-GET requests.
- **No library configuration.** No `config :sap`, no `System.get_env`, no process dictionary.
  Configuration belongs to the host's client module.
- **Fail closed.** A response that is not the expected OData shape is an error, never an empty
  result.
- **No bang functions** in the public API.

### Naming and layout

- A context module lives in its own directory: `lib/sap/customers/customers.ex`.
- Params are named resource, then action: `Sap.Customers.Params.Addresses.List`,
  `Sap.SalesOrders.Params.Items.Create`. Not `Params.ListAddresses` or `Params.Create.Item`.
- Response structs sit beside the context: `Sap.Customers.Address`,
  `Sap.SalesOrders.SalesOrder.Item`.
- One module per file. Every public module has a `@moduledoc`; every public function has `@doc`
  and `@spec`.

### Adding a resource

1. Context module of pure functions returning `%Sap.Operation{}` (`Sap.Customers` is the smallest
   example).
2. Params structs under `Params`, response structs beside the context, each with `from_odata/1`
   or `to_odata/1`.
3. If the resource has writes, add its service to `csrf_services/0` in
   `lib/sap/client/server.ex` so its token is fetched on boot.
4. Add every SAP field name you read or write to `@fields` in
   `test/integration/sandbox_test.exs`, so it is checked against `$metadata`.
5. Tests: builders as plain structs; HTTP behaviour through `Sap.ApiCase.start_client/2`.
6. Update the usage rules and skills (next section).

## Keep the usage rules and skills current

This package ships guidance for the agents of the apps that depend on it. It is part of the
public API: when it is wrong, agents in Conductor and Panorama write wrong code.

| File | Purpose |
|---|---|
| `usage-rules.md` | Rules that apply to every use of the library. |
| `usage-rules/skills/sap-client-setup/SKILL.md` | Defining, configuring and supervising a client. |
| `usage-rules/skills/sap-sales-orders/SKILL.md` | Creating and reading sales orders. |
| `usage-rules/skills/sap-customers/SKILL.md` | Reading customers. |

Rules for you:

- **Any change to public behaviour updates these files in the same change.** That includes a
  renamed module or function, a new or removed struct field that callers set, a new error kind, a
  changed default, and a changed configuration key.
- **A new resource gets a new skill**: `usage-rules/skills/sap-<resource>/SKILL.md`, with YAML
  frontmatter (`name`, `description`). Write the `description` as concrete triggers: module
  names, function names and error kinds an agent would see, not a topic label.
- **Add a skill for a workflow** when you find yourself explaining the same multi-step task twice
  (for example recovering from an unknown create outcome across systems).
- **Keep them short.** Rules and one working example per task. Details belong in module docs.
- **Every code example must be real.** Check each one against the current module and function
  names before you finish.
- Run `mix usage_rules.validate usage-rules.md usage-rules/skills/*/SKILL.md` after editing them.
- **Test a new or heavily changed skill in a clean app.** Create a fresh Mix project that depends
  on this library, add the `usage_rules` config below, run `mix usage_rules.sync --yes`, and give
  an agent with no other context a task the skill should cover. If the agent has to inspect
  structs or read `deps/` to finish, the skill is missing something: add it.

Host apps pull these in through their own `mix.exs`:

```elixir
usage_rules: [
  file: "AGENTS.md",
  usage_rules: [:sap],
  skills: [package_skills: [:sap]]
]
```

## Dependency rules

The section below is generated from this project's dependencies. Do not edit it by hand; run
`mix usage_rules.sync --yes` after adding or updating a dependency.


<!-- usage-rules-start -->
<!-- usage_rules-start -->
## usage_rules usage
_A config-driven dev tool for Elixir projects to manage AGENTS.md files and agent skills from dependencies_

[usage_rules usage rules](deps/usage_rules/usage-rules.md)
<!-- usage_rules-end -->
<!-- usage_rules:elixir-start -->
## usage_rules:elixir usage
[usage_rules:elixir usage rules](deps/usage_rules/usage-rules/elixir.md)
<!-- usage_rules:elixir-end -->
<!-- usage_rules:otp-start -->
## usage_rules:otp usage
[usage_rules:otp usage rules](deps/usage_rules/usage-rules/otp.md)
<!-- usage_rules:otp-end -->
<!-- usage-rules-end -->
