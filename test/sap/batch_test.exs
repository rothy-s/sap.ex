defmodule Sap.BatchTest do
  use Sap.ApiCase, async: true

  alias Sap.Batch
  alias Sap.Batch.Changeset
  alias Sap.Batch.Multipart
  alias Sap.Batch.Response
  alias Sap.Batch.Result
  alias Sap.Error
  alias Sap.Odata.Query
  alias Sap.Operation
  alias Sap.SalesOrders
  alias Sap.SalesOrders.Params
  alias Sap.SalesOrders.SalesOrder

  @service "API_SALES_ORDER_SRV"

  defp read, do: SalesOrders.get(%Params.Get{sales_order: "2000001", expand_items: false})

  defp create(material) do
    SalesOrders.create(%Params.Create{
      sales_order_type: "OR",
      sales_organization: "1000",
      distribution_channel: "10",
      organization_division: "00",
      sold_to_party: "100001",
      items: [%Params.Items.Create{material: material, requested_quantity: 1}]
    })
  end

  defp http(status, body) do
    payload =
      if body, do: "Content-Type: application/json\r\n\r\n" <> JSON.encode!(body), else: "\r\n"

    "Content-Type: application/http\r\n\r\nHTTP/1.1 #{status} X\r\n" <> payload <> "\r\n"
  end

  defp changeset(responses) do
    inner = Enum.map_join(responses, "", &("--cs\r\n" <> &1)) <> "--cs--\r\n"
    "Content-Type: multipart/mixed; boundary=cs\r\n\r\n" <> inner
  end

  defp multipart(parts), do: Enum.map_join(parts, "", &("--resp\r\n" <> &1)) <> "--resp--\r\n"

  defp batch_client(parts) do
    start_client(fn conn, _request ->
      conn
      |> Plug.Conn.put_resp_header("content-type", "multipart/mixed; boundary=resp")
      |> Plug.Conn.send_resp(202, multipart(parts))
    end)
  end

  describe "Multipart.encode/2" do
    test "writes service-relative request lines with %20 spaces, and bodies with their content type" do
      listing = %Operation{
        service: @service,
        path: "/A_SalesOrder",
        query: Query.new(filters: [{"SalesOrder", :eq, "1"}])
      }

      {body, content_type} = Multipart.encode([listing, create("SKU-1")], boundary: "b")

      assert content_type == "multipart/mixed; boundary=b"
      assert body =~ "GET A_SalesOrder?%24filter=SalesOrder%20eq%20%271%27&%24format=json HTTP/1.1"
      assert body =~ "POST A_SalesOrder HTTP/1.1\r\nContent-Type: application/json\r\n\r\n{"
      assert body =~ ~s("Material":"SKU-1")
      assert String.ends_with?(body, "--b--\r\n")
    end

    test "nests a changeset under its own boundary" do
      {body, _} =
        Multipart.encode([%Changeset{operations: [create("A"), create("B")]}],
          boundary: "b",
          changeset_boundary: "cs"
        )

      assert body =~ "--b\r\nContent-Type: multipart/mixed; boundary=cs\r\n\r\n--cs\r\n"
      assert body =~ "--cs--\r\n--b--\r\n"
      assert body |> String.split("POST A_SalesOrder HTTP/1.1") |> length() == 3
    end

    test "generates a different boundary each time" do
      {_, first} = Multipart.encode([read()])
      {_, second} = Multipart.encode([read()])

      refute first == second
    end
  end

  describe "Multipart.decode/2" do
    test "needs the boundary from the response content type" do
      assert Multipart.decode("x", nil) == {:error, :missing_content_type}
      assert Multipart.decode("x", "multipart/mixed") == {:error, :missing_batch_boundary}
    end

    test "returns a part that claims JSON but is not as text, and a bodyless part as nil" do
      body =
        multipart([
          "Content-Type: application/http\r\n\r\nHTTP/1.1 500 X\r\nContent-Type: application/json\r\n\r\nboom\r\n",
          http(204, nil)
        ])

      assert {:ok, [{:http, 500, _, "boom"}, {:http, 204, _, nil}]} =
               Multipart.decode(body, "multipart/mixed; boundary=\"resp\"")
    end
  end

  describe "a batch request" do
    test "is one CSRF-bearing POST to $batch, and decodes each part with its operation's decoder" do
      module =
        batch_client([
          http(200, %{"d" => %{"SalesOrder" => "2000001"}}),
          changeset([
            http(201, %{"d" => %{"SalesOrder" => "1"}}),
            http(201, %{"d" => %{"SalesOrder" => "2"}})
          ])
        ])

      batch = %Batch{
        service: @service,
        parts: [read(), %Changeset{operations: [create("A"), create("B")]}]
      }

      assert {:ok, %Response{parts: [read_result, changeset_result]} = response} =
               module.request(batch)

      assert %Result{status: 200, data: %SalesOrder{sales_order: "2000001"}, error: nil} =
               read_result

      assert %Changeset.Result{
               error: nil,
               results: [
                 %Result{status: 201, data: %SalesOrder{sales_order: "1"}},
                 %Result{data: %SalesOrder{sales_order: "2"}}
               ]
             } = changeset_result

      assert Response.ok?(response)

      assert [request] = received_requests()
      assert request.method == "POST"
      assert request.path == root() <> "/API_SALES_ORDER_SRV/$batch"
      assert request.headers["content-type"] =~ "multipart/mixed; boundary=batch_"
      assert is_binary(request.headers["x-csrf-token"])
      assert request.body =~ "GET A_SalesOrder('2000001')?%24format=json HTTP/1.1"
    end

    test "a failed part is reported in the part, not as a failed call" do
      module =
        batch_client([
          http(404, sap_error("/IWBEP/CM_MGW_RT/020", "Resource not found")),
          http(200, %{"d" => %{"SalesOrder" => "2000001"}})
        ])

      assert {:ok, %Response{parts: [missing, found]} = response} =
               module.request(%Batch{service: @service, parts: [read(), read()]})

      assert %Result{
               status: 404,
               data: nil,
               error: %Error{kind: :not_found, message: "Resource not found"}
             } = missing

      assert %Result{status: 200, error: nil} = found
      refute Response.ok?(response)
    end

    test "a failed changeset comes back as one error with no results" do
      rejection = sap_error("V1/801", "Material B is not defined")
      module = batch_client([http(400, rejection)])

      batch = %Batch{service: @service, parts: [%Changeset{operations: [create("A"), create("B")]}]}

      assert {:ok, %Response{parts: [%Changeset.Result{results: [], error: error}]} = response} =
               module.request(batch)

      assert %Error{kind: :http, status: 400, code: "V1/801", message: "Material B is not defined"} =
               error

      refute Response.ok?(response)
    end

    test "a part with no body decodes to nil" do
      module = batch_client([http(204, nil)])

      delete = %Operation{
        service: @service,
        method: :delete,
        path: "/A_SalesOrder('1')",
        shape: :none
      }

      assert {:ok, %Response{parts: [%Result{status: 204, data: nil, error: nil}]}} =
               module.request(%Batch{service: @service, parts: [delete]})
    end

    test "a 2xx part whose body is not the expected envelope carries a decode error" do
      module = batch_client([http(200, %{"unexpected" => true})])

      assert {:ok, %Response{parts: [%Result{status: 200, error: %Error{kind: :decode}}]}} =
               module.request(%Batch{service: @service, parts: [read()]})
    end

    test "a reply whose parts do not match the request is :decode" do
      fewer = batch_client([http(200, %{"d" => %{"SalesOrder" => "1"}})])

      assert {:error, %Error{kind: :decode, message: message}} =
               fewer.request(%Batch{service: @service, parts: [read(), read()]})

      assert message =~ "do not match"

      wrong_shape = batch_client([changeset([http(201, %{"d" => %{}})])])

      assert {:error, %Error{kind: :decode}} =
               wrong_shape.request(%Batch{service: @service, parts: [read()]})

      short_changeset = batch_client([changeset([http(201, %{"d" => %{}})])])

      assert {:error, %Error{kind: :decode}} =
               short_changeset.request(%Batch{
                 service: @service,
                 parts: [%Changeset{operations: [create("A"), create("B")]}]
               })
    end

    test "a reply that is not multipart is :decode" do
      module = start_client(fn conn, _request -> json(conn, 202, %{"d" => %{}}) end)

      assert {:error, %Error{kind: :decode}} =
               module.request(%Batch{service: @service, parts: [read()]})
    end

    test "a failed batch request is a failed call, sent once" do
      module = start_client(fn conn, _request -> json(conn, 500, %{}) end)

      assert {:error, %Error{kind: :http, status: 500}} =
               module.request(%Batch{service: @service, parts: [read()]})

      assert [_only_one] = received_requests()
    end

    test "is :not_started on a client that was never started" do
      module = define_client()

      assert {:error, %Error{kind: :not_started}} =
               module.request(%Batch{service: @service, parts: [read()]})
    end
  end
end
