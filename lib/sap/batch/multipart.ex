defmodule Sap.Batch.Multipart do
  @moduledoc false

  # Encodes and decodes OData **V2** `multipart/mixed` `$batch` payloads.
  #
  # Parts are `%Operation{}` values, either bare (independent) or grouped in a
  # `%Sap.Batch.Changeset{}` (atomic; SAP commits all or none). Reads must not go in a changeset.
  #
  # Changeset boundaries are read from the response's own `content-type` rather than matched against
  # SAP's current `changesetresponse_` naming, which would break silently if the gateway changed it.

  alias Sap.Batch.Changeset
  alias Sap.Odata.Query
  alias Sap.Operation

  @crlf "\r\n"

  @type part :: Operation.t() | Changeset.t()
  @type response_part ::
          {:http, non_neg_integer(), map(), term()}
          | {:changeset, [{:http, non_neg_integer(), map(), term()}]}

  @doc """
  Encodes `parts` into a `$batch` body.

  Returns `{body, content_type}`; the content type carries the generated boundary. Paths are made
  service-relative because SAP expects that inside a batch.
  """
  @spec encode([part()], keyword()) :: {String.t(), String.t()}
  def encode(parts, opts \\ []) when is_list(parts) do
    boundary = Keyword.get(opts, :boundary, unique_boundary("batch"))
    body = Enum.map_join(parts, "", &encode_part(&1, boundary, opts)) <> closing(boundary)

    {body, "multipart/mixed; boundary=#{boundary}"}
  end

  @doc """
  Decodes a `$batch` response body, given the response's `content-type`.

  Each returned part is `{:http, status, headers, body}`, or `{:changeset, [...]}` for a changeset
  group. Bodies are decoded JSON where the part says JSON, otherwise the raw string (or `nil`).
  """
  @spec decode(String.t(), String.t() | nil) :: {:ok, [response_part()]} | {:error, atom()}
  def decode(body, content_type) when is_binary(body) do
    with {:ok, boundary} <- boundary_of(content_type) do
      {:ok, body |> split(boundary) |> Enum.map(&decode_part/1)}
    end
  end

  @doc "A unique multipart boundary. Exposed so tests can pin one."
  @spec unique_boundary(String.t()) :: String.t()
  def unique_boundary(prefix), do: "#{prefix}_#{System.unique_integer([:positive])}"

  # ── encode ──────────────────────────────────────────────────────────────────

  defp encode_part(%Changeset{operations: operations}, boundary, opts) do
    inner = Keyword.get(opts, :changeset_boundary, unique_boundary("changeset"))

    [
      open(boundary),
      "Content-Type: multipart/mixed; boundary=#{inner}",
      @crlf,
      @crlf,
      Enum.map_join(operations, "", &encode_request(&1, inner)),
      closing(inner)
    ]
    |> IO.iodata_to_binary()
  end

  defp encode_part(%Operation{} = operation, boundary, _opts) do
    [open(boundary), encode_request_headers(), request_line(operation), @crlf]
    |> IO.iodata_to_binary()
  end

  defp encode_request(%Operation{} = operation, boundary) do
    [open(boundary), encode_request_headers(), request_line(operation), @crlf]
    |> IO.iodata_to_binary()
  end

  defp encode_request_headers do
    "Content-Type: application/http#{@crlf}Content-Transfer-Encoding: binary#{@crlf}#{@crlf}"
  end

  defp request_line(%Operation{} = operation) do
    method = operation.method |> Atom.to_string() |> String.upcase()
    url = relative_url(operation)
    headers = part_headers(operation)
    payload = payload(operation)

    header_block =
      case headers do
        [] -> ""
        list -> @crlf <> Enum.map_join(list, @crlf, fn {key, value} -> "#{key}: #{value}" end)
      end

    "#{method} #{url} HTTP/1.1#{header_block}#{@crlf}#{@crlf}#{payload}"
  end

  # A batched request's URL is relative to the service root, with no leading slash. Encoding goes
  # through Query so a batched part and a direct request cannot disagree about it.
  defp relative_url(%Operation{} = operation) do
    path = String.trim_leading(operation.path, "/")

    case Operation.params(operation) do
      [] -> path
      params -> path <> "?" <> Query.encode(params)
    end
  end

  # A part declares the content type its own body needs; auth and CSRF live on the enclosing
  # request, not on each part. Both come from `Operation` so a body cannot render differently here
  # than it would on a direct request.
  defp part_headers(%Operation{} = operation),
    do: operation.headers ++ Operation.content_type(operation)

  defp payload(%Operation{} = operation), do: Operation.encoded_body(operation) || ""

  defp open(boundary), do: "--#{boundary}#{@crlf}"
  defp closing(boundary), do: "--#{boundary}--#{@crlf}"

  # ── decode ──────────────────────────────────────────────────────────────────

  defp boundary_of(nil), do: {:error, :missing_content_type}

  defp boundary_of(content_type) when is_binary(content_type) do
    case Regex.run(~r/boundary=([^;\s]+)/, content_type) do
      [_, boundary] -> {:ok, boundary |> String.trim("\"") |> String.trim("'")}
      _ -> {:error, :missing_batch_boundary}
    end
  end

  defp split(body, boundary) do
    body
    |> String.split("--" <> boundary)
    |> Enum.map(&trim_part/1)
    |> Enum.reject(&(&1 == "" or &1 == "--" or not String.contains?(&1, "HTTP/1.1")))
  end

  defp trim_part(part) do
    part |> String.trim_leading("\r\n") |> String.trim_trailing("\r\n") |> String.trim()
  end

  defp decode_part(raw) do
    {meta, rest} = split_once(raw, "\r\n\r\n")

    case nested_boundary(meta) do
      nil -> decode_http(rest)
      boundary -> {:changeset, rest |> split(boundary) |> Enum.map(&decode_nested/1)}
    end
  end

  # The inner boundary is declared in the part's own Content-Type. Reading it from there rather than
  # pattern-matching SAP's boundary naming means a gateway change cannot silently break parsing.
  defp nested_boundary(meta) do
    content_type = meta |> header_lines() |> Map.get("content-type", "")

    if String.contains?(content_type, "multipart/mixed") do
      case boundary_of(content_type) do
        {:ok, boundary} -> boundary
        {:error, _} -> nil
      end
    end
  end

  defp decode_nested(part) do
    {_meta, http} = split_once(part, "\r\n\r\n")
    decode_http(http)
  end

  defp decode_http(raw) do
    {status_block, body} = raw |> String.trim_leading("\r\n") |> split_once("\r\n\r\n")
    {status, headers} = status_and_headers(status_block)

    {:http, status, headers, decode_body(body, headers)}
  end

  defp status_and_headers(block) do
    case String.split(block, "\r\n", trim: true) do
      [status_line | header_lines] ->
        {status_code(status_line), header_lines |> Enum.join("\r\n") |> header_lines()}

      [] ->
        {0, %{}}
    end
  end

  defp status_code(line) do
    line
    |> String.replace_prefix("HTTP/1.1 ", "")
    |> String.split(" ", parts: 2)
    |> List.first()
    |> Integer.parse()
    |> case do
      {status, _rest} -> status
      :error -> 0
    end
  end

  defp header_lines(block) when is_binary(block) do
    block
    |> String.split("\r\n", trim: true)
    |> Enum.reduce(%{}, fn line, acc ->
      case String.split(line, ":", parts: 2) do
        [key, value] ->
          Map.put(acc, key |> String.trim() |> String.downcase(), String.trim(value))

        _ ->
          acc
      end
    end)
  end

  defp decode_body(body, headers) when is_binary(body) do
    case String.trim(body) do
      "" -> nil
      trimmed -> maybe_json(trimmed, json_part?(headers))
    end
  end

  defp json_part?(headers),
    do: headers |> Map.get("content-type", "") |> String.contains?("json")

  # A part that claims JSON but does not parse is handed back as text rather than failing the whole
  # batch — the other parts are still useful.
  defp maybe_json(body, false), do: body

  defp maybe_json(body, true) do
    case JSON.decode(body) do
      {:ok, decoded} -> decoded
      _ -> body
    end
  end

  defp split_once(raw, delimiter) do
    case String.split(raw, delimiter, parts: 2) do
      [left, right] -> {left, right}
      [only] -> {only, ""}
    end
  end
end
