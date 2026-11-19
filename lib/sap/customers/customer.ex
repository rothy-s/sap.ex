defmodule Sap.Customers.Customer do
  @moduledoc """
  One SAP customer (an `A_Customer` row).

    * `:customer` - the customer number
    * `:name` - the display name: `CustomerName`, or `CustomerFullName` when that is blank.
    * `:account_group` - the customer account group
    * `:order_block`, `:delivery_block`, `:billing_block` - SAP's block reason codes, `nil` when
      the customer is not blocked
    * `:posting_blocked`, `:marked_for_deletion` - booleans
    * `:sales_areas` - `Sap.Customers.SalesArea` structs, `[]` unless the request expanded them
    * `:raw` - the row as SAP sent it
  """

  alias Sap.Customers.SalesArea
  alias Sap.Odata.Decode

  @type t :: %__MODULE__{
          customer: String.t(),
          name: String.t() | nil,
          account_group: String.t() | nil,
          order_block: String.t() | nil,
          delivery_block: String.t() | nil,
          billing_block: String.t() | nil,
          posting_blocked: boolean() | nil,
          marked_for_deletion: boolean() | nil,
          sales_areas: [SalesArea.t()],
          raw: map()
        }

  @enforce_keys [:customer]
  defstruct [
    :customer,
    name: nil,
    account_group: nil,
    order_block: nil,
    delivery_block: nil,
    billing_block: nil,
    posting_blocked: nil,
    marked_for_deletion: nil,
    sales_areas: [],
    raw: %{}
  ]

  @name_fields ~w(CustomerName CustomerFullName)

  @doc "Decodes an `A_Customer` row, or `nil` when it carries no customer number."
  @spec from_odata(map()) :: t() | nil
  def from_odata(row) when is_map(row) do
    case Decode.string(row["Customer"]) do
      nil ->
        nil

      customer ->
        %__MODULE__{
          customer: customer,
          name: Decode.first_string(row, @name_fields),
          account_group: Decode.string(row["CustomerAccountGroup"]),
          order_block: Decode.string(row["OrderIsBlockedForCustomer"]),
          delivery_block: Decode.string(row["DeliveryIsBlocked"]),
          billing_block: Decode.string(row["BillingIsBlockedForCustomer"]),
          posting_blocked: Decode.boolean(row["PostingIsBlocked"]),
          marked_for_deletion: Decode.boolean(row["DeletionIndicator"]),
          sales_areas:
            row |> Decode.nav("to_CustomerSalesArea") |> Enum.map(&SalesArea.from_odata/1),
          raw: row
        }
    end
  end
end
