defmodule Sap do
  @moduledoc """
  A client for SAP S/4HANA OData services.

  The library has two halves:

    * **Resource modules** describe what to do. `Sap.SalesOrders` and `Sap.Customers` take typed
      params structs and return a `Sap.Operation`: plain data, no I/O.
    * **A client module** you define with `Sap.Client` runs operations against one SAP system.

  ## Example

      defmodule MyApp.Sap do
        use Sap.Client, otp_app: :my_app
      end

      # config/runtime.exs
      config :my_app, MyApp.Sap,
        base_url: "https://sap.example.com",
        sap_client: "110",
        user: System.fetch_env!("SAP_USER"),
        password: System.fetch_env!("SAP_PASSWORD")

      # application.ex
      children = [MyApp.Sap]

      # anywhere
      alias Sap.SalesOrders.Params

      %Params.Create{
        sales_order_type: "OR",
        sales_organization: "1000",
        distribution_channel: "10",
        organization_division: "00",
        sold_to_party: "100001",
        purchase_order_by_customer: "PO-123",
        items: [%Params.Items.Create{material: "SKU-1", requested_quantity: 2}]
      }
      |> Sap.SalesOrders.create()
      |> MyApp.Sap.request()
      #=> {:ok, %Sap.SalesOrders.SalesOrder{sales_order: "12345"}}

  Every call returns `{:ok, result}` or `{:error, %Sap.Error{}}`.

  ## Where to look

    * `Sap.Client` - defining, configuring and supervising a client; retries; testing
    * `Sap.SalesOrders` - create, get and list sales orders
    * `Sap.Customers` - read customers, their sales areas, partner functions and addresses
    * `Sap.Batch` - several operations in one `$batch` request
    * `Sap.Error` - error kinds and which failures leave a write's outcome unknown
  """
end
