defmodule Sap.Customers.Address do
  @moduledoc """
  One address of a business partner (an `A_BusinessPartnerAddress` row).

  A row is keyed by `:business_partner` and `:address_id`. The postal fields and the display name
  are decoded; everything else SAP sends (PO box, time zone, tax jurisdiction) stays in `:raw`.
  """

  alias Sap.Odata.Decode

  @type t :: %__MODULE__{
          business_partner: String.t(),
          address_id: String.t(),
          full_name: String.t() | nil,
          street_name: String.t() | nil,
          additional_street_prefix_name: String.t() | nil,
          additional_street_suffix_name: String.t() | nil,
          house_number: String.t() | nil,
          city_name: String.t() | nil,
          region: String.t() | nil,
          postal_code: String.t() | nil,
          country: String.t() | nil,
          validity_start_date: Date.t() | nil,
          validity_end_date: Date.t() | nil,
          raw: map()
        }

  @enforce_keys [:business_partner, :address_id]
  defstruct [
    :business_partner,
    :address_id,
    full_name: nil,
    street_name: nil,
    additional_street_prefix_name: nil,
    additional_street_suffix_name: nil,
    house_number: nil,
    city_name: nil,
    region: nil,
    postal_code: nil,
    country: nil,
    validity_start_date: nil,
    validity_end_date: nil,
    raw: %{}
  ]

  @doc "Decodes an `A_BusinessPartnerAddress` row, or `nil` when it carries no usable key."
  @spec from_odata(map()) :: t() | nil
  def from_odata(row) when is_map(row) do
    with partner when is_binary(partner) <- Decode.string(row["BusinessPartner"]),
         address_id when is_binary(address_id) <- Decode.string(row["AddressID"]) do
      %__MODULE__{
        business_partner: partner,
        address_id: address_id,
        full_name: Decode.string(row["FullName"]),
        street_name: Decode.string(row["StreetName"]),
        additional_street_prefix_name: Decode.string(row["AdditionalStreetPrefixName"]),
        additional_street_suffix_name: Decode.string(row["AdditionalStreetSuffixName"]),
        house_number: Decode.string(row["HouseNumber"]),
        city_name: Decode.string(row["CityName"]),
        region: Decode.string(row["Region"]),
        postal_code: Decode.string(row["PostalCode"]),
        country: Decode.string(row["Country"]),
        validity_start_date: Decode.date(row["ValidityStartDate"]),
        validity_end_date: Decode.date(row["ValidityEndDate"]),
        raw: row
      }
    end
  end
end
