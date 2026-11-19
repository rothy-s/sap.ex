---
name: sap-client-setup
description: "Use when adding the sap library to an app, defining a module with `use Sap.Client`, configuring SAP credentials or environments (QA, production), setting `:csrf_refresh_interval` or other client options, adding a SAP client to a supervision tree, or debugging `%Sap.Error{kind: :not_started}`, `:csrf` or `:auth`."
---

# Setting up a SAP client

A client module is a connection to one SAP system. It works like an `Ecto.Repo`.

## Steps

1. Define a module per SAP system:

   ```elixir
   defmodule MyApp.SapQA do
     use Sap.Client, otp_app: :my_app
   end
   ```

2. Configure it under the host app, in `config/runtime.exs`:

   ```elixir
   config :my_app, MyApp.SapQA,
     base_url: "https://sap-qa.example.com",
     sap_client: "110",
     user: System.fetch_env!("SAP_QA_USER"),
     password: System.fetch_env!("SAP_QA_PASSWORD")
   ```

   Required: `:base_url`, `:sap_client`, `:user`, `:password`. Optional: `:receive_timeout`
   (default 60_000), `:csrf_refresh_interval` (default 15 minutes), `:csrf_timeout`
   (default 15_000), `:req_options`, `:adapter`.

3. Add it to the supervision tree, before anything that calls SAP while it boots:

   ```elixir
   children = [MyApp.SapQA]
   ```

4. For values only known at start, override `init/1`:

   ```elixir
   def init(options), do: {:ok, Keyword.put(options, :password, fetch_secret())}
   ```

## What the process does

- Validates the configuration on boot. Invalid configuration stops the app from starting, with a
  message naming the key.
- Fetches a CSRF token on boot and refreshes it on a timer. Requests run in the caller's process.

## CSRF token refresh

SAP requires a CSRF token on every write, and ties it to a session that expires when idle. The
client fetches a token on boot and refreshes it on a timer so writes always find one ready.

```elixir
config :my_app, MyApp.SapQA,
  csrf_refresh_interval: :timer.minutes(10),
  csrf_timeout: 15_000
```

| Key | Default | Meaning |
|---|---|---|
| `:csrf_refresh_interval` | `900_000` (15 minutes) | Milliseconds between refreshes. A positive integer. |
| `:csrf_timeout` | `15_000` | Milliseconds to wait for one token fetch. |

- Set `:csrf_refresh_interval` below the SAP system's session timeout. Ask the SAP team for it;
  it can differ between QA and production, and each client module has its own setting.
- Refresh cannot be switched off. An interval that is not a positive integer stops the client
  from starting.
- A too-long interval is not fatal: when SAP rejects a stale token, the client fetches a new one
  and resends that write once. It costs one extra round trip on the first write after expiry.
- A shorter interval means more requests to SAP: one `GET` per write service per interval.

## A custom HTTP client

The default adapter uses Req; `:req_options` are its options (TLS settings, `retry:` for reads).
To send requests with another HTTP client, implement `Sap.HTTP.Adapter`:

```elixir
defmodule MyApp.SapAdapter do
  @behaviour Sap.HTTP.Adapter

  @impl true
  def request(%Sap.HTTP.Request{} = request, options) do
    # request.method, request.url, request.headers, request.body, request.receive_timeout
    {:ok, %Sap.HTTP.Response{status: 200, headers: [{"content-type", "application/json"}], body: "..."}}
  end
end

config :my_app, MyApp.SapQA, adapter: {MyApp.SapAdapter, pool: :sap}
```

- Return every HTTP response as `{:ok, response}`, whatever its status. Do not follow redirects.
- Return `{:error, :timeout}` on a receive timeout; any other `{:error, reason}` is a transport
  failure.
- Never retry a request whose method is not `:get`.
- Return each `set-cookie` header as its own pair.
- With a custom adapter, `:req_options` and the test plug below have no effect.

## Testing

A started client fetches a CSRF token from SAP at once. So in the test environment, do not start
clients from the application; let each test start the one it needs with a plug.

```elixir
# application.ex
children = if Application.get_env(:my_app, :start_sap, true), do: [MyApp.SapQA], else: []

# config/test.exs
config :my_app, start_sap: false
```

```elixir
# in a test
plug = fn conn ->
  conn
  |> Plug.Conn.put_resp_header("x-csrf-token", "test-token")   # answers the token fetch too
  |> Plug.Conn.put_resp_content_type("application/json")
  |> Plug.Conn.send_resp(200, ~s({"d": {"Customer": "100001"}}))
end

start_supervised!(
  {MyApp.SapQA,
   base_url: "https://sap.test", sap_client: "110", user: "u", password: "p",
   req_options: [plug: plug]}
)
```

- Options given to `start_supervised!` override the application environment.
- The token fetch is a `GET` with the request header `x-csrf-token: Fetch`. It comes from the
  client's process, not the test's, so use a plain function plug (or
  `Req.Test.set_req_test_to_shared/1` with a `Req.Test` stub).
- `plug` needs `{:plug, "~> 1.20", only: :test}` in the host's deps.
- To simulate a transport failure: `Req.Test.transport_error(conn, :timeout)`.
- A client module is one named process, so tests that start the same module must use
  `async: false`.
- When `start_supervised!` stops the client at the end of a test, it is not started again: a
  later test that does not start it gets `:not_started`. Start the client in every test that
  calls SAP.

## Diagnosing errors

| `kind` | Usual cause |
|---|---|
| `:not_started` | The module is not in the supervision tree, or a script did not start the app. |
| `:auth` | Wrong user or password, or the user lacks authorization for the service. |
| `:csrf` | SAP was unreachable or refused the token fetch. The `status` and `message` say which. |
| `:html_session` | SAP returned a login page: wrong `:base_url`, or SSO in front of the gateway. |

## Rules

- No `config :sap`. All configuration belongs to the host's client module.
- Never read SAP credentials from the application environment yourself; call `MyApp.SapQA.config/0`.
- In a mix task or script, start the app (`Mix.Task.run("app.start")`) before any request.
