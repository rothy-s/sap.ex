defmodule Sap.HTTP.Adapter do
  @moduledoc """
  The behaviour between the library and the HTTP client that sends its requests.

  The library builds each request completely: URL, query string, authentication, CSRF token,
  cookies and body. An adapter only sends it and reports what came back. Everything else (CSRF
  handling, error classification, decoding) stays in the library, so it behaves the same with
  any adapter.

  The default adapter is `Sap.HTTP.ReqAdapter`. To use your own, name it in the client's
  configuration:

      config :my_app, MyApp.Sap, adapter: MyApp.SapAdapter
      # or, with options that are passed to every call:
      config :my_app, MyApp.Sap, adapter: {MyApp.SapAdapter, pool: :sap}

  ## Writing an adapter

      defmodule MyApp.SapAdapter do
        @behaviour Sap.HTTP.Adapter

        @impl true
        def request(%Sap.HTTP.Request{} = request, options) do
          case MyHTTP.send(request.method, request.url, request.headers, request.body,
                 timeout: request.receive_timeout, pool: options[:pool]) do
            {:ok, status, headers, body} ->
              {:ok, %Sap.HTTP.Response{status: status, headers: headers, body: body}}

            {:error, :timeout} ->
              {:error, :timeout}

            {:error, reason} ->
              {:error, reason}
          end
        end
      end

  An adapter must follow these rules:

    * **Return every HTTP response as `{:ok, response}`**, whatever its status. A 404 or a 500 is
      a response, not an error. Do not follow redirects.
    * **Return `{:error, :timeout}`** when no response arrived within `:receive_timeout`. Any other
      `{:error, reason}` is reported as a transport failure.
    * **Never retry a request whose method is not `:get`.** SAP has no idempotency key: a replayed
      POST creates a second document. Retrying a `:get` is your choice.
    * **Send the URL, headers and body unchanged.** The query string is already encoded.
    * **Return all `set-cookie` headers**, one pair each. The CSRF handshake needs them.

  The adapter is also called from the client's own process, for the CSRF token fetches it makes
  on boot and on its refresh timer.
  """

  alias Sap.HTTP.Request
  alias Sap.HTTP.Response

  @doc """
  Sends `request` and returns the response.

  `options` is the keyword list given beside the adapter in the client's configuration
  (`adapter: {module, options}`), or `[]`.
  """
  @callback request(request :: Request.t(), options :: keyword()) ::
              {:ok, Response.t()} | {:error, :timeout | term()}
end
