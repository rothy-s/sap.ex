defmodule Sap.Odata.Encode do
  @moduledoc """
  Elixir values to the SAP wire forms: dates, numbers, escaped literals, ALPHA zero-padding and
  OData key predicates.

  The write-side counterpart to `Sap.Odata.Decode`.
  """

  @doc """
  A `Date` as SAP's epoch-milliseconds literal.

      iex> alias Sap.Odata.Encode
      iex> Encode.epoch(~D[2026-01-01])
      "/Date(1767225600000)/"
      iex> Encode.epoch(nil)
      nil
  """
  @spec epoch(Date.t() | nil) :: String.t() | nil
  def epoch(nil), do: nil

  def epoch(%Date{} = date) do
    milliseconds =
      date
      |> DateTime.new!(~T[00:00:00], "Etc/UTC")
      |> DateTime.to_unix(:millisecond)

    "/Date(#{milliseconds})/"
  end

  @doc """
  A number as the plain decimal string SAP expects.

  Quantities and amounts stay strings end to end - SAP sends `Edm.Decimal` as a JSON string to
  preserve precision, and this client does not reinterpret it - so the usual argument here is
  already a binary and passes straight through. Integers and `Decimal`s are accepted too.

  Floats are **rejected** with an `ArgumentError`. `Float.to_string/1` can produce exponent
  notation, which SAP rejects on quantity and amount fields, and a float has already lost the
  precision the string form was protecting.

      iex> alias Sap.Odata.Encode
      iex> Encode.number("24.000")
      "24.000"
      iex> Encode.number(24)
      "24"
      iex> Encode.number(Decimal.new("1.50"))
      "1.50"
  """
  @spec number(integer() | String.t() | Decimal.t() | nil) :: String.t() | nil
  def number(nil), do: nil
  def number(value) when is_integer(value), do: Integer.to_string(value)
  def number(value) when is_binary(value), do: String.trim(value)
  def number(%Decimal{} = value), do: Decimal.to_string(value, :normal)

  def number(value) when is_float(value) do
    raise ArgumentError,
          "SAP numbers must be an integer, a Decimal or a decimal string, got float #{value}"
  end

  @doc """
  A value as an OData string-literal body, with embedded single quotes doubled.

  Used for both `$filter` comparisons and key predicates in a path — `A_SalesOrderItem
  (SalesOrder='O''Brien')`. Returns the escaped text **without** surrounding quotes; the caller
  adds those, since a key predicate and a filter clause place them differently.

      iex> alias Sap.Odata.Encode
      iex> Encode.escape("O'Brien")
      "O''Brien"
  """
  @spec escape(term()) :: String.t()
  def escape(value), do: value |> to_string() |> String.replace("'", "''")

  @doc """
  An OData key predicate, escaped and parenthesized.

  A single value renders unnamed, several render as named parts:

      iex> alias Sap.Odata.Encode
      iex> Encode.key("4600111454")
      "('4600111454')"
      iex> Encode.key(SalesOrder: "2000001", SalesOrderItem: "000010")
      "(SalesOrder='2000001',SalesOrderItem='000010')"

  Worth having in one place: every call site was interpolating quotes by hand, and a single missed
  `escape/1` turns a customer code containing an apostrophe into a malformed request.

      iex> alias Sap.Odata.Encode
      iex> Encode.key(Customer: "O'Brien")
      "(Customer='O''Brien')"
  """
  @spec key(term()) :: String.t()
  def key(parts) when is_list(parts) do
    "(" <> Enum.map_join(parts, ",", fn {name, value} -> "#{name}='#{escape(value)}'" end) <> ")"
  end

  def key(value), do: "('" <> escape(value) <> "')"

  @doc """
  Drops entries whose value is `nil` or `""`.

  SAP distinguishes "absent" from "explicitly blank" — sending `"Supplier": ""` clears the field
  rather than leaving it alone — so a payload should carry only what the caller meant.

      iex> alias Sap.Odata.Encode
      iex> Encode.compact(%{"A" => "x", "B" => nil, "C" => ""})
      %{"A" => "x"}
  """
  @spec compact(map()) :: map()
  def compact(map) when is_map(map),
    do: Map.reject(map, fn {_key, value} -> value in [nil, ""] end)

  @doc """
  The rows of a deep-insert navigation property, or `nil` when there are none.

  `nil` lets `compact/1` drop the property, so an empty list is not sent at all.

      iex> alias Sap.Odata.Encode
      iex> Encode.children([1, 2], &(&1 * 2))
      [2, 4]
      iex> Encode.children([], &(&1 * 2))
      nil
  """
  @spec children([struct], (struct -> map())) :: [map()] | nil when struct: term()
  def children([], _encoder), do: nil
  def children(rows, encoder) when is_list(rows), do: Enum.map(rows, encoder)
end
