defmodule Sap.Operation do
  @moduledoc """
  An inert description of one SAP OData call.

  Resource modules such as `Sap.SalesOrders` build operations; a client module (see `Sap.Client`)
  runs them. An operation is plain data and knows nothing about which SAP system will run it, so
  it can be asserted on in a test with no network.

  ## Fields

    * `:service` - the OData service, for example `"API_SALES_ORDER_SRV"`.
    * `:method`, `:path`, `:query`, `:body`, `:headers` - the request.
    * `:shape` - what the response holds: `:entity`, `:collection`, `:none` or `:raw`.
    * `:decoder` - a function applied to the entity, or to each row of a collection. A row decoder
      may return `nil` to drop a row.
    * `:csrf` - `nil` derives the answer from the method; a boolean overrides it.
    * `:receive_timeout` - milliseconds; `nil` uses the client's default.
    * `:truncation` - `:error` refuses a paginated response (`d.__next`); `:ignore` accepts it.
    * `:page_size`, `:max_pages` - paging for `c:Sap.Client.stream/3`.
  """

  alias Sap.Odata.Query

  @type service :: String.t()
  @type shape :: :entity | :collection | :none | :raw
  @type method :: :get | :post | :patch | :put | :delete
  @type parser :: :json | :text
  @type body :: map() | {:raw, iodata()} | nil
  @type decoder :: (map() -> term()) | nil

  @type t :: %__MODULE__{
          service: service(),
          method: method(),
          path: String.t(),
          query: Query.t() | [{String.t(), String.t()}] | nil,
          body: body(),
          headers: [{String.t(), String.t()}],
          shape: shape(),
          decoder: decoder(),
          csrf: boolean() | nil,
          parser: parser(),
          receive_timeout: pos_integer() | nil,
          truncation: :error | :ignore,
          page_size: pos_integer(),
          max_pages: pos_integer()
        }

  @enforce_keys [:service]
  defstruct service: nil,
            method: :get,
            path: "",
            query: nil,
            body: nil,
            headers: [],
            shape: :entity,
            decoder: nil,
            csrf: nil,
            parser: :json,
            receive_timeout: nil,
            truncation: :error,
            page_size: 500,
            max_pages: 5_000

  @doc """
  Whether this operation needs a CSRF token.

  SAP Gateway enforces the token on every state-changing request and never on a `GET`.

      iex> Sap.Operation.csrf?(%Sap.Operation{service: "API_SALES_ORDER_SRV", method: :get})
      false
      iex> Sap.Operation.csrf?(%Sap.Operation{service: "API_SALES_ORDER_SRV", method: :post})
      true
      iex> Sap.Operation.csrf?(%Sap.Operation{service: "S", method: :post, csrf: false})
      false
  """
  @spec csrf?(t()) :: boolean()
  def csrf?(%__MODULE__{csrf: csrf}) when is_boolean(csrf), do: csrf
  def csrf?(%__MODULE__{method: :get}), do: false
  def csrf?(%__MODULE__{}), do: true

  @doc """
  The `Content-Type` header this operation's body needs, as a list to concatenate.

  A bodyless request declares none, a map is JSON, and a pre-encoded `{:raw, _}` body carries its
  own in `:headers`.

      iex> Sap.Operation.content_type(%Sap.Operation{service: "S"})
      []
      iex> Sap.Operation.content_type(%Sap.Operation{service: "S", body: %{"A" => 1}})
      [{"Content-Type", "application/json"}]
      iex> Sap.Operation.content_type(%Sap.Operation{service: "S", body: {:raw, "..."}})
      []
  """
  @spec content_type(t()) :: [{String.t(), String.t()}]
  def content_type(%__MODULE__{body: nil}), do: []
  def content_type(%__MODULE__{body: {:raw, _payload}}), do: []
  def content_type(%__MODULE__{}), do: [{"Content-Type", "application/json"}]

  @doc """
  The operation's body as bytes, or `nil` when it has none.

  Both the direct request path and the `$batch` encoder use this, so a body cannot render one way
  on its own and another way inside a batch.

      iex> Sap.Operation.encoded_body(%Sap.Operation{service: "S"})
      nil
      iex> Sap.Operation.encoded_body(%Sap.Operation{service: "S", body: {:raw, "encoded"}})
      "encoded"
      iex> Sap.Operation.encoded_body(%Sap.Operation{service: "S", body: %{"A" => 1}})
      ~s({"A":1})
  """
  @spec encoded_body(t()) :: String.t() | nil
  def encoded_body(%__MODULE__{body: nil}), do: nil
  def encoded_body(%__MODULE__{body: {:raw, payload}}), do: IO.iodata_to_binary(payload)
  def encoded_body(%__MODULE__{body: body}) when is_map(body), do: JSON.encode!(body)

  @doc """
  The operation's query as an ordered `{key, value}` list.

      iex> Sap.Operation.params(%Sap.Operation{service: "S"})
      []
      iex> Sap.Operation.params(%Sap.Operation{service: "S", query: [{"$top", "1"}]})
      [{"$top", "1"}]
  """
  @spec params(t()) :: [{String.t(), String.t()}]
  def params(%__MODULE__{query: nil}), do: []
  def params(%__MODULE__{query: %Query{} = query}), do: Query.params(query)
  def params(%__MODULE__{query: params}) when is_list(params), do: params
end
