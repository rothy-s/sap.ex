defprotocol Sap.Odata.Filterable do
  @moduledoc """
  A params struct that renders its own `$filter` clauses.

  Implemented by the list params of each resource (for example `Sap.SalesOrders.Params.List`).
  `to_filter/1` returns only clauses that **narrow** the result set. Shaping options such as
  `$expand` and `$top` are applied by the resource module, which owns that knowledge.
  """

  alias Sap.Odata.Query

  @doc "The `$filter` clauses this input implies, as a `Query` carrying filters only."
  @spec to_filter(t()) :: Query.t()
  def to_filter(input)
end
