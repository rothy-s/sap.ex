defmodule Sap.Odata.Date do
  @moduledoc """
  Resolves "since when" into a single `Date`: an explicit date, else a rolling day count, else no
  bound.

  Several resources accept both forms, so something has to decide which wins; this is that decision,
  in one place rather than four.

  Call it as `Odata.Date` rather than aliasing it directly - a bare `alias` of this module shadows
  Elixir's own `Date` for the rest of the file, which is a trap for the next person to reach for
  `Date.utc_today/0` there.
  """

  @doc """
  An explicit date wins; otherwise a positive day count becomes that many days ago; otherwise `nil`,
  meaning no lower bound at all.

      iex> alias Sap.Odata
      iex> Odata.Date.since(~D[2026-01-01], 30)
      ~D[2026-01-01]
      iex> Odata.Date.since(nil, nil)
      nil
      iex> Odata.Date.since(nil, 0)
      nil
  """
  @spec since(Date.t() | nil, integer() | nil) :: Date.t() | nil
  def since(%Date{} = from_date, _days), do: from_date

  def since(_from_date, days) when is_integer(days) and days > 0,
    do: Date.add(Date.utc_today(), -days)

  def since(_from_date, _days), do: nil
end
