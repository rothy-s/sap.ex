defmodule Sap.Batch.Response do
  @moduledoc """
  The decoded reply to a `Sap.Batch`: one entry per part, in request order.

  An operation yields a `Sap.Batch.Result`; a changeset yields a `Sap.Batch.Changeset.Result`.

  > #### Part failures are not call failures {: .warning}
  >
  > A failed part is reported in that part, **not** as `{:error, _}` from the request. Use `ok?/1`
  > or inspect the parts.
  """

  alias Sap.Batch
  alias Sap.Batch.Changeset
  alias Sap.Batch.Result
  alias Sap.Error
  alias Sap.HTTP.Envelope
  alias Sap.Operation

  @type part :: Result.t() | Changeset.Result.t()
  @type t :: %__MODULE__{parts: [part()]}

  defstruct parts: []

  @doc "Whether every part succeeded."
  @spec ok?(t()) :: boolean()
  def ok?(%__MODULE__{parts: parts}) do
    Enum.all?(parts, fn
      %Result{} = result -> Result.ok?(result)
      %Changeset.Result{} = result -> Changeset.Result.ok?(result)
    end)
  end

  @doc false
  # Pairs the decoded multipart parts with the operations that produced them. SAP answers in
  # request order, so position is the only correlation there is.
  @spec build(Batch.t(), [Batch.Multipart.response_part()]) :: {:ok, t()} | {:error, Error.t()}
  def build(%Batch{parts: requested, service: service}, decoded)
      when length(requested) == length(decoded) do
    requested
    |> Enum.zip(decoded)
    |> Enum.reduce_while([], fn pair, acc ->
      case part(pair, service) do
        {:ok, part} -> {:cont, [part | acc]}
        :error -> {:halt, :error}
      end
    end)
    |> case do
      :error -> {:error, mismatch(service)}
      parts -> {:ok, %__MODULE__{parts: Enum.reverse(parts)}}
    end
  end

  def build(%Batch{service: service}, _decoded), do: {:error, mismatch(service)}

  defp part({%Operation{} = op, {:http, status, headers, body}}, _service),
    do: {:ok, result(op, status, headers, body)}

  defp part({%Changeset{operations: ops}, {:changeset, responses}}, _service)
       when length(ops) == length(responses) do
    results =
      ops
      |> Enum.zip(responses)
      |> Enum.map(fn {op, {:http, status, headers, body}} -> result(op, status, headers, body) end)

    {:ok, %Changeset.Result{results: results}}
  end

  # A changeset that fails is answered with one error in place of the whole group.
  defp part({%Changeset{}, {:http, status, _headers, body}}, service) when status >= 400,
    do: {:ok, %Changeset.Result{error: error(service, nil, status, body)}}

  defp part(_pair, _service), do: :error

  defp result(%Operation{} = op, status, headers, body) when status in 200..299 do
    case Envelope.unwrap(body, part_shape(op, body), service: op.service, status: status) do
      {:ok, data} -> %Result{status: status, headers: headers, data: data}
      {:error, error} -> %Result{status: status, headers: headers, error: error}
    end
  end

  defp result(%Operation{} = op, status, headers, body),
    do: %Result{status: status, headers: headers, error: error(op.service, op.method, status, body)}

  # A part with no body (a 204) has nothing to decode, whatever the operation asked for.
  defp part_shape(op, nil), do: %{op | shape: :none}
  defp part_shape(op, _body), do: op

  defp error(service, method, 404, body),
    do: Error.new(:not_found, service: service, method: method, status: 404, body: body)

  defp error(service, method, status, body),
    do: Error.new(:http, service: service, method: method, status: status, body: body)

  defp mismatch(service) do
    Error.new(:decode,
      service: service,
      message: "the $batch response parts do not match the request parts"
    )
  end
end
