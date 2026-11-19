defmodule Sap.Customers.Params.Addresses.List do
  @moduledoc """
  Params for `Sap.Customers.list_addresses/1`: whose addresses to read.

  One business partner per call. SAP exposes addresses through the owning partner, so there is
  no list of numbers to combine.
  """

  @type t :: %__MODULE__{business_partner: String.t()}

  @enforce_keys [:business_partner]
  defstruct [:business_partner]
end
