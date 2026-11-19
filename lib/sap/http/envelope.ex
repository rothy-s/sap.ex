defmodule Sap.HTTP.Envelope do
  @moduledoc false

  # Turns a raw SAP response body into the shape an operation asked for.
  #
  # The HTML-login gate runs on every textual body: SAP answers HTTP 200 with its Fiori login page
  # when a session lapses, and a client that does not check parses it as an empty result set,
  # which reads as "SAP has no rows for you". Everything here fails closed: a body that is not
  # the expected OData envelope is an error, never an empty result.

  alias Sap.Error
  alias Sap.Operation

  @type context :: [
          url: String.t() | nil,
          service: String.t() | nil,
          method: atom() | nil,
          status: non_neg_integer() | nil
        ]

  @doc "Decodes `body` according to `op`."
  @spec unwrap(term(), Operation.t(), context()) :: {:ok, term()} | {:error, Error.t()}
  def unwrap(body, %Operation{} = op, context \\ []) do
    with :ok <- reject_html(body, context) do
      decode(body, op, context)
    end
  end

  defp reject_html(body, context) when is_binary(body) do
    if html_login_or_session_page?(body) do
      {:error, Error.new(:html_session, context)}
    else
      :ok
    end
  end

  defp reject_html(_body, _context), do: :ok

  defp decode(body, %Operation{shape: :raw}, _context), do: {:ok, body}
  defp decode(_body, %Operation{shape: :none}, _context), do: {:ok, nil}
  defp decode(body, %Operation{parser: :text}, _context), do: {:ok, body}

  defp decode(body, %Operation{} = op, context) when is_binary(body) do
    case JSON.decode(body) do
      {:ok, decoded} when is_map(decoded) -> decode(decoded, op, context)
      _ -> {:error, Error.new(:decode, context ++ [message: "SAP response was not a JSON object"])}
    end
  end

  defp decode(body, %Operation{} = op, context) when is_map(body) do
    with :ok <- reject_truncated(body, op, context),
         {:ok, extracted} <- extract(body, op.shape) do
      {:ok, apply_decoder(extracted, op)}
    else
      :error ->
        {:error,
         Error.new(:decode, context ++ [message: "SAP response had no OData #{op.shape} envelope"])}

      {:error, %Error{}} = error ->
        error
    end
  end

  defp decode(_body, _op, context),
    do: {:error, Error.new(:decode, context ++ [message: "SAP response had no body to decode"])}

  defp reject_truncated(_body, %Operation{truncation: :ignore}, _context), do: :ok

  defp reject_truncated(%{"d" => %{"__next" => next}}, _op, context)
       when is_binary(next) and next != "",
       do: {:error, Error.new(:truncated, context)}

  defp reject_truncated(_body, _op, _context), do: :ok

  # OData V2 wraps everything in `d`. A collection is `d.results`, or on some services a bare list.
  defp extract(%{"d" => %{"results" => rows}}, :collection) when is_list(rows), do: {:ok, rows}
  defp extract(%{"d" => rows}, :collection) when is_list(rows), do: {:ok, rows}
  defp extract(%{"d" => entity}, :entity) when is_map(entity), do: {:ok, entity}
  defp extract(_body, _shape), do: :error

  # A row decoder may return nil to drop a row it cannot make sense of.
  defp apply_decoder(rows, %Operation{decoder: nil}) when is_list(rows), do: rows

  defp apply_decoder(rows, %Operation{decoder: decoder}) when is_list(rows),
    do: rows |> Enum.map(decoder) |> Enum.reject(&is_nil/1)

  defp apply_decoder(entity, %Operation{decoder: nil}), do: entity
  defp apply_decoder(entity, %Operation{decoder: decoder}), do: decoder.(entity)

  # SAP may answer HTTP 200 with HTML - the Fiori login form or the "already logged on" session
  # chooser - instead of OData JSON, on the very same TLS session that served JSON a moment ago.
  defp html_login_or_session_page?(body) do
    prefix = String.slice(body, 0, 16_000)
    classic_login_page?(prefix) or html_401_page?(String.downcase(prefix))
  end

  defp classic_login_page?(prefix) do
    String.contains?(prefix, "<!DOCTYPE html") and
      String.contains?(prefix, [
        "Logon Status Check",
        "sap-system-login",
        "SESSIONS_LIST",
        "loginForm",
        "sapUiBody"
      ])
  end

  # Gateway and ICM often return 401 + HTML with no DOCTYPE, and not always in English.
  defp html_401_page?(lower) do
    String.contains?(lower, "<html") and
      String.contains?(lower, [
        "401 nicht autorisiert",
        "401 unauthorized",
        "401 not authorized",
        "anmeldung fehlgeschlagen"
      ])
  end
end
