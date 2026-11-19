defmodule Sap.Odata.Decode do
  @moduledoc """
  SAP wire values to Elixir values, shared by every response struct's `from_odata/1`.

  SAP's OData V2 representation is stringly-typed: amounts as strings, dates as
  `/Date(epoch_ms)/`, absent values as `""`. Every function here is total: a value that cannot be
  coerced becomes `nil` rather than raising, so one malformed field does not fail a whole page.

  The read-side counterpart to `Sap.Odata.Encode`.
  """

  @doc "Trimmed string, or `nil` when absent or blank."
  @spec string(term()) :: String.t() | nil
  def string(nil), do: nil

  def string(value) when is_binary(value) do
    case String.trim(value) do
      "" -> nil
      trimmed -> trimmed
    end
  end

  def string(value), do: value |> to_string() |> string()

  @doc """
  The first non-blank value among `keys`.

  SAP moves some fields between names across releases and configurations — a GTIN sits in either
  `ProductStandardID` or `InternationalArticleNumberCat` — so readers try several in precedence
  order.
  """
  @spec first_string(map(), [String.t()]) :: String.t() | nil
  def first_string(row, keys) when is_map(row) and is_list(keys),
    do: Enum.find_value(keys, &string(row[&1]))

  @doc """
  A `Date` from SAP's `/Date(epoch_ms)/` form or a plain ISO-8601 string.

  SAP sometimes appends a timezone offset (`/Date(1767225600000+0000)/`), which is stripped. Values
  that parse as neither are `nil`.
  """
  @spec date(term()) :: Date.t() | nil
  def date(nil), do: nil
  def date(%Date{} = date), do: date
  def date(%DateTime{} = datetime), do: DateTime.to_date(datetime)

  def date("/Date(" <> rest) do
    rest
    |> String.trim_trailing(")/")
    |> String.split(~r/[+-](?=\d{4}$)/, parts: 2)
    |> hd()
    |> Integer.parse()
    |> case do
      {milliseconds, ""} -> from_epoch_ms(milliseconds)
      _ -> nil
    end
  end

  def date(value) when is_binary(value) do
    case value |> String.split("T") |> hd() |> Date.from_iso8601() do
      {:ok, date} -> date
      _ -> nil
    end
  end

  def date(_), do: nil

  @doc """
  A boolean, or `nil` when absent. SAP sends real JSON booleans, and `"X"`/`""` on older fields.
  """
  @spec boolean(term()) :: boolean() | nil
  def boolean(value) when is_boolean(value), do: value
  def boolean("X"), do: true
  def boolean("true"), do: true
  def boolean("false"), do: false
  def boolean(""), do: false
  def boolean(_value), do: nil

  @doc """
  The rows under a navigation property, whatever shape SAP sent them in.

  An expansion arrives as `%{"results" => rows}`, a bare list, or a single map. A property that
  was not expanded arrives as `%{"__deferred" => link}` and yields `[]`, as does an absent one.
  """
  @spec nav(map(), String.t()) :: [map()]
  def nav(row, name) when is_map(row) do
    case row[name] do
      %{"results" => rows} when is_list(rows) -> Enum.filter(rows, &is_map/1)
      %{"__deferred" => _link} -> []
      rows when is_list(rows) -> Enum.filter(rows, &is_map/1)
      %{} = single when map_size(single) > 0 -> [single]
      _absent -> []
    end
  end

  defp from_epoch_ms(milliseconds) do
    case DateTime.from_unix(milliseconds, :millisecond) do
      {:ok, datetime} -> DateTime.to_date(datetime)
      _ -> nil
    end
  end
end
