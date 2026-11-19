defmodule Sap.Error do
  @moduledoc """
  The one error every SAP call returns, with a `:kind` to match on.

  | Kind | Meaning |
  |---|---|
  | `:not_started` | The client module was never started, or is down and the call needs its process. |
  | `:transport` | The request did not complete (connection refused, closed, DNS). |
  | `:timeout` | No response within the receive timeout. |
  | `:http` | SAP answered with a non-2xx status not covered below. |
  | `:not_found` | SAP answered 404. |
  | `:auth` | SAP answered 401, or 403 without asking for a CSRF token. |
  | `:html_session` | SAP answered with an HTML login or session page instead of OData. |
  | `:decode` | The response body was not the OData shape the operation expects. |
  | `:csrf` | A CSRF token could not be fetched, or SAP rejected a fresh one. |
  | `:truncated` | SAP paginated a response the operation required in full. |

  ## Writes and unknown outcomes

  The library never retries. When a **write** fails with `:timeout`, `:transport`, or `:http` with
  a 5xx status, SAP may still have processed it: the outcome is unknown, not failed. Check SAP
  (for example by the customer's purchase order number) before sending the request again.

  ## SAP's own error data

  `:code` is SAP's `error.code` (for example `"V1/801"`), `:message` is the most specific message
  SAP gave, and `:details` holds every `errordetails` row as `Sap.Error.Detail` structs. `:body`
  is the raw response body.
  """

  alias Sap.Error.Detail

  @type kind ::
          :not_started
          | :transport
          | :timeout
          | :http
          | :not_found
          | :auth
          | :html_session
          | :decode
          | :csrf
          | :truncated

  @type t :: %__MODULE__{
          kind: kind(),
          service: String.t() | nil,
          method: atom() | nil,
          url: String.t() | nil,
          status: non_neg_integer() | nil,
          code: String.t() | nil,
          message: String.t() | nil,
          details: [Detail.t()],
          body: term(),
          reason: term()
        }

  defexception [
    :kind,
    :service,
    :method,
    :url,
    :status,
    :code,
    :message,
    :body,
    :reason,
    details: []
  ]

  @generic_sap_message "Exception raised without specific error"
  @max_message 800

  @doc """
  Builds an error, filling `:code`, `:details` and `:message` from the SAP body when present.
  """
  @spec new(kind(), keyword()) :: t()
  def new(kind, fields \\ []) do
    error = struct!(__MODULE__, Keyword.put(fields, :kind, kind))
    sap = sap_error(error.body)

    %{
      error
      | code: error.code || code(sap),
        details: details(sap),
        message: error.message || derive_message(error, sap)
    }
  end

  @impl Exception
  def message(%__MODULE__{} = error) do
    [
      "SAP #{error.kind}",
      error.service && "service=#{error.service}",
      error.status && "status=#{error.status}",
      error.code && "code=#{error.code}",
      error.url && "url=#{error.url}",
      error.message
    ]
    |> Enum.reject(&(&1 in [nil, false]))
    |> Enum.join(" ")
  end

  # ── message ─────────────────────────────────────────────────────────────────

  defp derive_message(%__MODULE__{kind: :not_started}, _sap),
    do: "the SAP client is not started; add it to your supervision tree"

  defp derive_message(%__MODULE__{kind: :html_session}, _sap),
    do: "SAP returned an HTML login or session page instead of OData"

  defp derive_message(%__MODULE__{kind: :truncated}, _sap),
    do: "SAP response was paginated and partial results were refused"

  defp derive_message(%__MODULE__{kind: kind, reason: reason}, _sap)
       when kind in [:transport, :timeout] and not is_nil(reason),
       do: inspect(reason)

  defp derive_message(%__MODULE__{body: nil}, _sap), do: nil
  defp derive_message(%__MODULE__{}, %{} = sap), do: sap_message(sap)

  # Never the whole body: it can carry order and customer data that must not reach a log.
  defp derive_message(%__MODULE__{body: body}, nil) when is_binary(body),
    do: String.slice(body, 0, @max_message)

  defp derive_message(%__MODULE__{body: body}, nil),
    do: body |> inspect(limit: 50) |> String.slice(0, @max_message)

  # SAP often sends a generic wrapper message plus the actionable one in `errordetails`; prefer the
  # specific one.
  defp sap_message(sap) do
    messages = sap |> detail_rows() |> Enum.map(& &1["message"]) |> Enum.filter(&text?/1)
    specific = Enum.find(messages, &(&1 != @generic_sap_message))

    specific || List.first(messages) || top_level_message(sap) || "SAP error"
  end

  defp top_level_message(%{"message" => %{"value" => value}}) when is_binary(value), do: value
  defp top_level_message(%{"message" => value}) when is_binary(value), do: value
  defp top_level_message(_sap), do: nil

  # ── body parsing ────────────────────────────────────────────────────────────

  defp sap_error(body) when is_binary(body) do
    case JSON.decode(body) do
      {:ok, decoded} -> sap_error(decoded)
      _ -> nil
    end
  end

  defp sap_error(%{"error" => %{} = error}), do: error
  defp sap_error(_body), do: nil

  defp code(%{"code" => code}) when is_binary(code) and code != "", do: code
  defp code(_sap), do: nil

  defp details(nil), do: []

  defp details(sap),
    do: sap |> detail_rows() |> Enum.map(&Detail.from_odata/1) |> Enum.reject(&is_nil/1)

  # The details live at `error.errordetails` or under `error.innererror.errordetails`, depending
  # on the gateway response; both are gathered.
  defp detail_rows(sap) do
    inner =
      case sap["innererror"] do
        %{"errordetails" => rows} -> rows
        _ -> []
      end

    Enum.filter(List.wrap(sap["errordetails"]) ++ List.wrap(inner), &is_map/1)
  end

  defp text?(value), do: is_binary(value) and value != ""
end
