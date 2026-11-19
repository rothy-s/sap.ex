defmodule Sap.Batch do
  @moduledoc """
  Several operations sent to SAP in one OData `$batch` request.

  Every part must belong to `:service`. A part is either a `Sap.Operation` (independent) or a
  `Sap.Batch.Changeset` (a group of writes SAP commits together or not at all).

      %Sap.Batch{
        service: Sap.SalesOrders.service(),
        parts: [
          Sap.SalesOrders.get(%Sap.SalesOrders.Params.Get{sales_order: "1"}),
          %Sap.Batch.Changeset{operations: [create_one, create_two]}
        ]
      }
      |> MyApp.Sap.request()
      #=> {:ok, %Sap.Batch.Response{}}

  The batch is a single POST. Like any write it is never retried: a replayed batch replays its
  writes.
  """

  alias Sap.Batch.Changeset
  alias Sap.Operation

  @type part :: Operation.t() | Changeset.t()
  @type t :: %__MODULE__{
          service: Operation.service(),
          parts: [part()],
          receive_timeout: pos_integer() | nil
        }

  @enforce_keys [:service, :parts]
  defstruct [:service, :parts, :receive_timeout]
end
