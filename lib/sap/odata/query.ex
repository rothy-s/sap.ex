defmodule Sap.Odata.Query do
  @moduledoc """
  OData system query options — `$filter`, `$select`, `$expand`, `$orderby`, `$top`, `$skip`,
  `$format` — composed and rendered.

  Values are encoded by type; `:in` expands to an OR group because OData V2 has no native `in`.
  Spaces render as `%20`, not `+`, which some SAP gateways reject.
  """

  alias Sap.Odata.Encode

  @operators %{eq: "eq", ne: "ne", gt: "gt", ge: "ge", lt: "lt", le: "le"}

  @type operator :: :eq | :ne | :gt | :ge | :lt | :le | :in
  @type value :: String.t() | number() | boolean() | {:raw, String.t()}
  @type direction :: :asc | :desc
  @type order_clause :: String.t() | {String.t(), direction()}
  @type raw_clause :: {:raw, String.t()}
  @type clause :: {String.t(), operator(), value() | [value()]} | raw_clause()

  @type t :: %__MODULE__{
          filters: [clause()],
          select: [String.t()],
          expand: [String.t()],
          order_by: [order_clause()],
          top: non_neg_integer() | nil,
          skip: non_neg_integer() | nil,
          format: String.t() | nil
        }

  defstruct filters: [], select: [], expand: [], order_by: [], top: nil, skip: nil, format: "json"

  @doc """
  Builds an options struct from data.

  Opts: `:filters`, `:select`, `:expand`, `:order_by`, `:top`, `:skip`, and `:format` (default
  `"json"`, pass `nil` to omit — `$metadata` and the CSRF fetch need it gone).
  """
  @spec new(keyword()) :: t()
  def new(opts \\ []) do
    %__MODULE__{
      filters: Keyword.get(opts, :filters, []),
      select: Keyword.get(opts, :select, []),
      expand: Keyword.get(opts, :expand, []),
      order_by: Keyword.get(opts, :order_by, []),
      top: Keyword.get(opts, :top),
      skip: Keyword.get(opts, :skip),
      format: Keyword.get(opts, :format, "json")
    }
  end

  @doc """
  Appends a `{field, op, value}` filter clause.

  `:in` takes a list, which renders as an OR group — OData V2 has no native `in`.
  """
  @spec where(t(), String.t(), operator(), value() | [value()]) :: t()
  def where(%__MODULE__{filters: filters} = query, field, op, value),
    do: %{query | filters: filters ++ [{field, op, value}]}

  @doc """
  Appends a pre-formatted `$filter` expression, AND-combined with the other clauses.

  For expressions the `{field, op, value}` form cannot express — an operator-configured extra filter
  carried in config, `substringof(...)`, a nested `and`/`or` group. Emitted verbatim, so the caller
  owns its escaping; use `Sap.Odata.Encode.escape/1`.
  """
  @spec where_raw(t(), String.t() | nil) :: t()
  def where_raw(%__MODULE__{} = query, nil), do: query

  def where_raw(%__MODULE__{filters: filters} = query, expression) when is_binary(expression) do
    case String.trim(expression) do
      "" -> query
      trimmed -> %{query | filters: filters ++ [{:raw, trimmed}]}
    end
  end

  @doc """
  Adds `<field> ge datetime'<date>T00:00:00'`.

  A date bound has to be an unquoted `Edm.DateTime` literal, not a quoted string, or SAP rejects the
  request. `nil` leaves the options untouched so an optional bound can be piped straight through.
  """
  @spec on_or_after(t(), String.t(), Date.t() | nil) :: t()
  def on_or_after(%__MODULE__{} = query, _field, nil), do: query

  def on_or_after(%__MODULE__{} = query, field, %Date{} = date),
    do: where(query, field, :ge, {:raw, "datetime'#{Date.to_iso8601(date)}T00:00:00'"})

  @doc """
  Adds one OR group matching any of `values` in any of `fields`.

  SAP carries a customer's reference number in whichever field the document-creation path happened
  to populate, so a lookup has to try them all. Empty values leave the options untouched.
  """
  @spec any_of(t(), [String.t()], [String.t()] | nil) :: t()
  def any_of(%__MODULE__{} = query, _fields, nil), do: query
  def any_of(%__MODULE__{} = query, _fields, []), do: query

  def any_of(%__MODULE__{} = query, fields, values) when is_list(fields) and is_list(values) do
    expression =
      for value <- values, field <- fields do
        "#{field} eq '#{Encode.escape(value)}'"
      end
      |> Enum.join(" or ")

    where_raw(query, expression)
  end

  @doc "Appends one or more `$select` field names."
  @spec select(t(), [String.t()] | String.t()) :: t()
  def select(%__MODULE__{select: existing} = query, fields),
    do: %{query | select: existing ++ List.wrap(fields)}

  @doc "Appends one or more `$expand` navigation properties."
  @spec expand(t(), [String.t()] | String.t()) :: t()
  def expand(%__MODULE__{expand: existing} = query, properties),
    do: %{query | expand: existing ++ List.wrap(properties)}

  @doc """
  Appends `$orderby` clauses.

  Each is a bare field name (SAP defaults to ascending) or a `{field, :asc | :desc}` tuple.
  """
  @spec order_by(t(), [order_clause()] | order_clause()) :: t()
  def order_by(%__MODULE__{order_by: existing} = query, clauses),
    do: %{query | order_by: existing ++ List.wrap(clauses)}

  @doc "Sets `$top` (page size). `nil` omits it."
  @spec top(t(), non_neg_integer() | nil) :: t()
  def top(%__MODULE__{} = query, n) when is_nil(n) or (is_integer(n) and n >= 0),
    do: %{query | top: n}

  @doc "Sets `$skip` (offset). `nil` omits it."
  @spec skip(t(), non_neg_integer() | nil) :: t()
  def skip(%__MODULE__{} = query, n) when is_nil(n) or (is_integer(n) and n >= 0),
    do: %{query | skip: n}

  @doc """
  Ordered `{key, value}` param list, empty parts dropped.

  `$format` stays last so an encoded query string is unchanged when no paging or expansion is used.

      iex> alias Sap.Odata.Query
      iex> Query.new(filters: [{"SalesOrder", :eq, "2000001"}], select: ["Material"])
      ...> |> Query.params()
      [{"$filter", "SalesOrder eq '2000001'"}, {"$select", "Material"}, {"$format", "json"}]

  `:in` expands to a parenthesized OR group:

      iex> alias Sap.Odata.Query
      iex> Query.new(filters: [{"GoodsMovementType", :in, ["107", "108"]}])
      ...> |> Query.params()
      [{"$filter", "(GoodsMovementType eq '107' or GoodsMovementType eq '108')"}, {"$format", "json"}]
  """
  @spec params(t()) :: [{String.t(), String.t()}]
  def params(%__MODULE__{} = query) do
    [
      {"$filter", render_filter(query.filters)},
      {"$select", render_list(query.select)},
      {"$expand", render_list(query.expand)},
      {"$orderby", render_order_by(query.order_by)},
      {"$top", render_int(query.top)},
      {"$skip", render_int(query.skip)},
      {"$format", query.format}
    ]
    |> Enum.reject(fn {_key, value} -> is_nil(value) end)
  end

  @doc """
  Narrows by `field` when a value was given: one value is an equality, a list matches any of them,
  and `nil` or `[]` leaves the query alone.

      iex> alias Sap.Odata.Query
      iex> Query.new() |> Query.match("Material", "SKU-1") |> Query.params() |> hd()
      {"$filter", "Material eq 'SKU-1'"}
      iex> Query.new() |> Query.match("Material", ["A", "B"]) |> Query.params() |> hd()
      {"$filter", "(Material eq 'A' or Material eq 'B')"}
      iex> Query.new() |> Query.match("Material", nil) |> Query.params()
      [{"$format", "json"}]
  """
  @spec match(t(), String.t(), String.t() | [String.t()] | nil) :: t()
  def match(%__MODULE__{} = query, _field, nil), do: query
  def match(%__MODULE__{} = query, _field, []), do: query

  def match(%__MODULE__{} = query, field, value) when is_binary(value),
    do: where(query, field, :eq, value)

  def match(%__MODULE__{} = query, field, values) when is_list(values),
    do: where(query, field, :in, Enum.map(values, &to_string/1))

  @doc "Encoded query string with no leading `?`, spaces as `%20`."
  @spec query_string(t()) :: String.t()
  def query_string(%__MODULE__{} = query), do: query |> params() |> encode()

  @doc """
  Encodes an already-rendered param list.

  Split out from `query_string/1` because `$batch` builds its part URLs from a param list rather than
  an options struct, and both paths must apply the same `%20` rule — some SAP gateways reject the `+`
  form, and a batched request diverging from a direct one on that point would be a miserable bug to
  find.
  """
  @spec encode([{String.t(), String.t()}]) :: String.t()
  def encode(params) when is_list(params) do
    params
    |> URI.encode_query()
    |> String.replace("+", "%20")
  end

  defp render_filter([]), do: nil
  defp render_filter(clauses), do: Enum.map_join(clauses, " and ", &clause/1)

  defp render_list([]), do: nil
  defp render_list(values), do: Enum.join(values, ",")

  defp render_order_by([]), do: nil
  defp render_order_by(clauses), do: Enum.map_join(clauses, ",", &order/1)

  defp render_int(nil), do: nil
  defp render_int(n) when is_integer(n), do: Integer.to_string(n)

  defp order({field, :asc}) when is_binary(field), do: field <> " asc"
  defp order({field, :desc}) when is_binary(field), do: field <> " desc"
  defp order(field) when is_binary(field), do: field

  defp order(other) do
    raise ArgumentError,
          "unsupported OData $orderby clause #{inspect(other)}; " <>
            "use a field name or {field, :asc | :desc}"
  end

  # Parenthesized so a pre-formatted expression containing a top-level `or` composes safely with the
  # surrounding `and`.
  defp clause({:raw, expression}) when is_binary(expression), do: "(" <> expression <> ")"

  defp clause({_field, :in, []}),
    do: raise(ArgumentError, "OData :in clause requires a non-empty value list")

  defp clause({field, :in, values}) when is_list(values),
    do: "(" <> Enum.map_join(values, " or ", &"#{field} eq #{literal(&1)}") <> ")"

  defp clause({field, op, value}), do: "#{field} #{operator(op)} #{literal(value)}"

  defp operator(op) do
    Map.get(@operators, op) ||
      raise ArgumentError,
            "unsupported OData operator #{inspect(op)}; " <>
              "expected one of #{inspect(Map.keys(@operators))}"
  end

  defp literal({:raw, value}) when is_binary(value), do: value
  defp literal(value) when is_binary(value), do: "'" <> String.replace(value, "'", "''") <> "'"
  defp literal(value) when is_integer(value) or is_float(value), do: to_string(value)
  defp literal(true), do: "true"
  defp literal(false), do: "false"

  defp literal(value) do
    raise ArgumentError,
          "unsupported OData filter value #{inspect(value)}; " <>
            "use a binary, number, boolean, or {:raw, string}"
  end
end
