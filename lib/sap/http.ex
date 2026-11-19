defmodule Sap.HTTP do
  @moduledoc false

  # Executes operations: builds each request, hands it to the client's `Sap.HTTP.Adapter`, and
  # turns what comes back into a result or a `Sap.Error`.
  #
  # Two rules here are safety properties, not tuning knobs:
  #
  #   * The library never retries. Adapters must not retry a non-GET either (the default adapter
  #     enforces it), because SAP has no idempotency key and a replayed POST creates a second
  #     document.
  #   * The one automatic resend is the CSRF handshake: a `403` with `x-csrf-token: Required`
  #     means SAP rejected the request before processing it, so sending it again with a fresh
  #     token is safe even for a write. It happens exactly once.

  alias Sap.Batch
  alias Sap.Batch.Multipart
  alias Sap.Client
  alias Sap.Client.Config
  alias Sap.Error
  alias Sap.HTTP.Envelope
  alias Sap.HTTP.Request
  alias Sap.HTTP.Response
  alias Sap.Odata.Query
  alias Sap.Operation

  @odata_v2_prefix "/sap/opu/odata/sap"

  @doc "Runs `op` for the client `module`, returning the decoded result."
  @spec run(module(), Config.t(), Operation.t()) :: {:ok, term()} | {:error, Error.t()}
  def run(module, %Config{} = config, %Operation{} = op) do
    with {:ok, %Response{} = resp} <- send_request(module, config, op) do
      Envelope.unwrap(resp.body, op, context(config, op, resp.status))
    end
  end

  @doc "Runs `batch` as a single `$batch` POST."
  @spec run_batch(module(), Config.t(), Batch.t()) ::
          {:ok, Batch.Response.t()} | {:error, Error.t()}
  def run_batch(module, %Config{} = config, %Batch{} = batch) do
    {body, content_type} = Multipart.encode(batch.parts)

    envelope = %Operation{
      service: batch.service,
      method: :post,
      path: "/$batch",
      body: {:raw, body},
      headers: [{"Content-Type", content_type}],
      parser: :text,
      shape: :raw,
      receive_timeout: batch.receive_timeout
    }

    # SAP picks its own boundary for the reply, so it can only be split using the boundary in
    # the response's own content-type.
    with {:ok, %Response{} = resp} <- send_request(module, config, envelope),
         context = context(config, envelope, resp.status),
         {:ok, text} <- Envelope.unwrap(resp.body, envelope, context),
         {:ok, parts} <- split_batch(text, resp, context) do
      Batch.Response.build(batch, parts)
    end
  end

  defp split_batch(text, resp, context) when is_binary(text) do
    content_type = resp |> Response.header("content-type") |> List.first()

    case Multipart.decode(text, content_type) do
      {:ok, parts} ->
        {:ok, parts}

      {:error, reason} ->
        {:error,
         Error.new(:decode, context ++ [message: "could not split the $batch response: #{reason}"])}
    end
  end

  defp split_batch(_body, _resp, context),
    do:
      {:error,
       Error.new(:decode, context ++ [message: "the $batch response had no multipart body"])}

  @doc """
  Fetches a CSRF token and its session cookies for `service`.

  SAP returns the token in a response header and binds it to the session in `Set-Cookie`; a write
  needs both.
  """
  @spec fetch_csrf(Config.t(), Operation.service()) ::
          {:ok, %{token: String.t(), cookies: map()}} | {:error, Error.t()}
  def fetch_csrf(%Config{} = config, service) do
    probe = %Operation{service: service, path: "/", query: [{"$format", "json"}]}
    fields = base_fields(config, probe)

    request = %Request{
      method: :get,
      url: url(config, probe),
      headers: common_headers(config, probe) ++ [{"x-csrf-token", "Fetch"}],
      receive_timeout: config.csrf_timeout
    }

    case call(config, request) do
      {:ok, %Response{status: status} = resp} when status in 200..299 ->
        token_from(resp, fields)

      {:ok, %Response{status: status, body: body}} ->
        {:error, Error.new(:csrf, fields ++ [status: status, body: body])}

      {:error, reason} ->
        {:error,
         Error.new(
           :csrf,
           fields ++ [reason: reason, message: "CSRF token fetch failed: #{inspect(reason)}"]
         )}
    end
  end

  defp token_from(%Response{} = resp, fields) do
    case resp |> Response.header("x-csrf-token") |> List.first() do
      token when is_binary(token) and token != "" ->
        {:ok, %{token: token, cookies: cookies(resp)}}

      _missing ->
        {:error,
         Error.new(
           :csrf,
           fields ++ [status: resp.status, message: "SAP returned no x-csrf-token header"]
         )}
    end
  end

  defp cookies(%Response{} = resp) do
    resp
    |> Response.header("set-cookie")
    |> Enum.reduce(%{}, fn cookie, acc ->
      case cookie |> String.split(";", parts: 2) |> hd() |> String.split("=", parts: 2) do
        [name, value] -> Map.put(acc, String.trim(name), String.trim(value))
        _ -> acc
      end
    end)
  end

  # ── one request ─────────────────────────────────────────────────────────────

  defp send_request(module, config, op) do
    with {:ok, session} <- session(module, op) do
      case dispatch(config, op, session) do
        {:csrf_stale, error} -> rotate_once(module, config, op, session, error)
        result -> result
      end
    end
  end

  defp session(module, %Operation{} = op) do
    if Operation.csrf?(op), do: Client.session(module, op.service), else: {:ok, nil}
  end

  defp rotate_once(module, config, op, session, error) do
    with {:ok, fresh} <- Client.rotate(module, op.service, session.generation) do
      case dispatch(config, op, fresh) do
        # A second `Required` means something other than a stale token.
        {:csrf_stale, _again} -> {:error, error}
        result -> result
      end
    end
  end

  defp dispatch(config, op, session) do
    case call(config, request(config, op, session)) do
      {:ok, %Response{status: status} = resp} when status in 200..299 -> {:ok, resp}
      {:ok, %Response{} = resp} -> classify(config, op, resp)
      {:error, reason} -> {:error, transport_error(config, op, reason)}
    end
  end

  # The single place an adapter is called. A misbehaving adapter is reported, not trusted.
  defp call(%Config{adapter: {adapter, options}}, %Request{} = request) do
    case adapter.request(request, options) do
      {:ok, %Response{}} = ok -> ok
      {:error, _reason} = error -> error
      other -> {:error, {:bad_adapter_return, other}}
    end
  end

  defp classify(config, op, %Response{status: 403, body: body} = resp) do
    fields = base_fields(config, op) ++ [status: 403, body: body]

    if csrf_required?(resp) and Operation.csrf?(op) do
      {:csrf_stale, Error.new(:csrf, fields)}
    else
      {:error, Error.new(:auth, fields)}
    end
  end

  defp classify(config, op, %Response{status: status, body: body}) do
    {:error, Error.new(kind(status), base_fields(config, op) ++ [status: status, body: body])}
  end

  defp kind(401), do: :auth
  defp kind(404), do: :not_found
  defp kind(_status), do: :http

  defp csrf_required?(%Response{} = resp) do
    resp
    |> Response.header("x-csrf-token")
    |> Enum.any?(&(String.downcase(&1) == "required"))
  end

  defp transport_error(config, op, :timeout),
    do: Error.new(:timeout, base_fields(config, op) ++ [reason: :timeout])

  defp transport_error(config, op, reason),
    do: Error.new(:transport, base_fields(config, op) ++ [reason: reason])

  # ── request construction ────────────────────────────────────────────────────

  defp request(config, op, session) do
    %Request{
      method: op.method,
      url: url(config, op),
      headers: headers(config, op) ++ session_headers(session),
      body: Operation.encoded_body(op),
      receive_timeout: op.receive_timeout || config.receive_timeout
    }
  end

  # The operation's own headers come last and must override, not duplicate: a `$batch` request
  # declares `multipart/mixed`, and sending `application/json` beside it is ambiguous.
  defp headers(config, op) do
    (common_headers(config, op) ++ Operation.content_type(op) ++ op.headers)
    |> Enum.reverse()
    |> Enum.uniq_by(fn {name, _value} -> String.downcase(name) end)
    |> Enum.reverse()
  end

  defp common_headers(config, op) do
    [
      {"Authorization", "Basic " <> Base.encode64("#{config.user}:#{config.password}")},
      {"sap-client", config.sap_client}
    ] ++ accept(op)
  end

  defp accept(%Operation{parser: :json}), do: [{"Accept", "application/json"}]
  defp accept(%Operation{}), do: []

  defp session_headers(nil), do: []

  defp session_headers(%{token: token, cookies: cookies}),
    do: [{"x-csrf-token", token}] ++ cookie_header(cookies)

  defp cookie_header(cookies) when map_size(cookies) == 0, do: []

  defp cookie_header(cookies),
    do: [{"Cookie", Enum.map_join(cookies, "; ", fn {name, value} -> "#{name}=#{value}" end)}]

  # The query string is built here, not by the adapter, so spaces render as `%20`: some SAP gateways
  # reject the `+` form.
  defp url(config, op) do
    base = config.base_url <> @odata_v2_prefix <> "/" <> op.service <> op.path

    case Operation.params(op) do
      [] -> base
      params -> base <> "?" <> Query.encode(params)
    end
  end

  defp base_fields(config, op), do: [service: op.service, method: op.method, url: url(config, op)]

  defp context(config, op, status), do: base_fields(config, op) ++ [status: status]
end
