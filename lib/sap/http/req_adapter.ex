defmodule Sap.HTTP.ReqAdapter do
  @moduledoc """
  The default `Sap.HTTP.Adapter`, built on [Req](https://hexdocs.pm/req).

  Its options are Req options, merged into every request. Set them with the client's
  `:req_options` key:

      config :my_app, MyApp.Sap,
        req_options: [connect_options: [transport_opts: [cacertfile: "/etc/ssl/sap-ca.pem"]]]

  Common uses are TLS settings, a `:plug` in tests, and `retry:` for reads
  (`retry: :safe_transient`).

  Req's own retries are off by default, and stay off for every request that is not a `GET`
  whatever the options say.
  """

  @behaviour Sap.HTTP.Adapter

  alias Sap.HTTP.Request
  alias Sap.HTTP.Response

  @impl Sap.HTTP.Adapter
  def request(%Request{} = request, options) do
    [
      method: request.method,
      url: request.url,
      headers: request.headers,
      receive_timeout: request.receive_timeout,
      retry: false,
      redirect: false
    ]
    |> put_body(request.body)
    |> Keyword.merge(options)
    |> never_retry_writes(request)
    |> Req.request()
    |> case do
      {:ok, %Req.Response{} = response} ->
        {:ok, %Response{status: response.status, headers: headers(response), body: response.body}}

      {:error, %{reason: :timeout}} ->
        {:error, :timeout}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp put_body(options, nil), do: options
  defp put_body(options, body), do: Keyword.put(options, :body, body)

  defp never_retry_writes(options, %Request{method: :get}), do: options
  defp never_retry_writes(options, %Request{}), do: Keyword.put(options, :retry, false)

  # Req keeps headers as `%{name => [values]}`; the behaviour wants one pair per value.
  defp headers(%Req.Response{headers: headers}) do
    for {name, values} <- headers, value <- List.wrap(values), do: {name, value}
  end
end
