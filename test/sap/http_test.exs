defmodule Sap.HTTPTest do
  use Sap.ApiCase, async: true

  alias Sap.Error
  alias Sap.Odata.Query
  alias Sap.Operation

  @service "API_BUSINESS_PARTNER"

  defp get(path \\ "/A_Customer('1')", fields \\ []),
    do: struct!(%Operation{service: @service, path: path}, fields)

  defp respond(status \\ 200, body) do
    start_client(fn conn, _request -> json(conn, status, body) end)
  end

  describe "the request" do
    test "goes to the service under the OData root with auth, mandant and accept headers" do
      module = respond(%{"d" => %{"Customer" => "1"}})

      assert {:ok, %{"Customer" => "1"}} = module.request(get())

      assert [request] = received_requests()
      assert request.method == "GET"
      assert request.path == root() <> "/API_BUSINESS_PARTNER/A_Customer('1')"
      assert request.headers["authorization"] == "Basic " <> Base.encode64("user:secret")
      assert request.headers["sap-client"] == "110"
      assert request.headers["accept"] == "application/json"
      refute Map.has_key?(request.headers, "x-csrf-token")
    end

    test "encodes spaces in the query as %20, never +" do
      module = respond(%{"d" => %{"results" => []}})
      query = Query.new(filters: [{"CustomerName", :eq, "Acme Shoes"}])

      assert {:ok, []} = module.request(get("/A_Customer", shape: :collection, query: query))

      assert [request] = received_requests()
      assert request.query_string =~ "CustomerName%20eq%20%27Acme%20Shoes%27"
      refute request.query_string =~ "+"
      assert request.query["$format"] == "json"
    end

    test "uses the operation's receive_timeout over the client's" do
      module =
        start_client(fn conn, _request -> Req.Test.transport_error(conn, :timeout) end,
          receive_timeout: 5_000
        )

      assert {:error, %Error{kind: :timeout}} =
               module.request(get("/A_Customer", receive_timeout: 1))
    end
  end

  describe "decoding" do
    test "applies the decoder to an entity and to each row, dropping nil rows" do
      decoder = fn row -> if row["Customer"] != "", do: {:customer, row["Customer"]} end

      entity = respond(%{"d" => %{"Customer" => "1"}})
      assert {:ok, {:customer, "1"}} = entity.request(get("/A_Customer('1')", decoder: decoder))

      rows = respond(%{"d" => %{"results" => [%{"Customer" => "1"}, %{"Customer" => ""}]}})

      assert {:ok, [customer: "1"]} =
               rows.request(get("/A_Customer", shape: :collection, decoder: decoder))
    end

    test "accepts a bare list under d as a collection" do
      module = respond(%{"d" => [%{"Customer" => "1"}]})

      assert {:ok, [%{"Customer" => "1"}]} = module.request(get("/A_Customer", shape: :collection))
    end

    test "an unrecognised collection envelope is a decode error, never an empty list" do
      module = respond(%{"value" => [%{"Customer" => "1"}]})

      assert {:error, %Error{kind: :decode, status: 200}} =
               module.request(get("/A_Customer", shape: :collection))
    end

    test "an entity response without the d envelope is a decode error" do
      module = respond(%{"Customer" => "1"})

      assert {:error, %Error{kind: :decode}} = module.request(get())
    end

    test "a paginated response is refused unless the operation ignores truncation" do
      body = %{"d" => %{"results" => [%{"Customer" => "1"}], "__next" => "https://sap.test/next"}}
      module = respond(body)

      assert {:error, %Error{kind: :truncated}} =
               module.request(get("/A_Customer", shape: :collection))

      assert {:ok, [_row]} =
               module.request(get("/A_Customer", shape: :collection, truncation: :ignore))
    end

    test "an HTML login page served with status 200 is :html_session" do
      html =
        "<!DOCTYPE html><html><body class=\"sapUiBody\"><form id=\"loginForm\"></form></body></html>"

      module =
        start_client(fn conn, _request ->
          conn |> Plug.Conn.put_resp_content_type("text/html") |> Plug.Conn.send_resp(200, html)
        end)

      assert {:error, %Error{kind: :html_session}} =
               module.request(get("/A_Customer", shape: :collection))
    end

    test "a non-JSON body is a decode error" do
      module =
        start_client(fn conn, _request ->
          conn |> Plug.Conn.put_resp_content_type("text/plain") |> Plug.Conn.send_resp(200, "oops")
        end)

      assert {:error, %Error{kind: :decode}} = module.request(get())
    end

    test "shape :none returns nil and shape :raw returns the body" do
      module = respond(%{"d" => %{"Customer" => "1"}})

      assert {:ok, nil} = module.request(get("/A_Customer('1')", shape: :none))
      assert {:ok, %{"d" => _}} = module.request(get("/A_Customer('1')", shape: :raw))
    end
  end

  describe "failures" do
    test "404 is :not_found" do
      module = respond(404, sap_error("/IWBEP/CM_MGW_RT/020", "Resource not found"))

      assert {:error, %Error{kind: :not_found, status: 404, code: "/IWBEP/CM_MGW_RT/020"} = error} =
               module.request(get())

      assert error.message == "Resource not found"
      assert error.service == @service
      assert error.method == :get
    end

    test "401 and a plain 403 are :auth" do
      assert {:error, %Error{kind: :auth, status: 401}} = respond(401, %{}).request(get())
      assert {:error, %Error{kind: :auth, status: 403}} = respond(403, %{}).request(get())
    end

    test "a 403 asking for a CSRF token on a read is :auth, not a rotation" do
      module =
        start_client(fn conn, _request ->
          conn |> Plug.Conn.put_resp_header("x-csrf-token", "Required") |> json(403, %{})
        end)

      assert {:error, %Error{kind: :auth}} = module.request(get())
      assert [_one] = received_requests()
    end

    test "a 500 is :http and is not retried" do
      module = respond(500, sap_error("SY/530", "Internal error"))

      assert {:error, %Error{kind: :http, status: 500, code: "SY/530"}} = module.request(get())
      assert [_one] = received_requests()
    end

    test "a transport failure is :transport and a timeout is :timeout, neither retried" do
      refused = start_client(fn conn, _request -> Req.Test.transport_error(conn, :econnrefused) end)
      assert {:error, %Error{kind: :transport}} = refused.request(get())
      assert [_one] = received_requests()

      slow = start_client(fn conn, _request -> Req.Test.transport_error(conn, :timeout) end)
      assert {:error, %Error{kind: :timeout}} = slow.request(get())
      assert [_one] = received_requests()
    end

    test "the host can switch on read retries through req_options" do
      {:ok, attempts} = Agent.start_link(fn -> 0 end)

      module =
        start_client(
          fn conn, _request ->
            case Agent.get_and_update(attempts, &{&1, &1 + 1}) do
              0 -> json(conn, 503, %{})
              _ -> json(conn, %{"d" => %{"Customer" => "1"}})
            end
          end,
          req_options: [
            retry: :safe_transient,
            retry_delay: fn _attempt -> 1 end,
            retry_log_level: false
          ]
        )

      assert {:ok, %{"Customer" => "1"}} = module.request(get())
      assert [_first, _second] = received_requests()
    end
  end

  describe "stream/3" do
    defp paging_client(pages) do
      start_client(fn conn, request ->
        index =
          div(String.to_integer(request.query["$skip"]), String.to_integer(request.query["$top"]))

        json(conn, %{"d" => %{"results" => Enum.at(pages, index, [])}})
      end)
    end

    test "pages until a short page, folding rows through the reducer" do
      module =
        paging_client([[%{"n" => 1}, %{"n" => 2}], [%{"n" => 3}, %{"n" => 4}], [%{"n" => 5}]])

      operation = get("/A_Customer", shape: :collection, page_size: 2, decoder: & &1["n"])

      assert {:ok, [1, 2, 3, 4, 5]} = module.stream(operation, [], &(&2 ++ &1))

      assert [
               %{query: %{"$skip" => "0", "$top" => "2"}},
               %{query: %{"$skip" => "2"}},
               %{query: %{"$skip" => "4"}}
             ] =
               received_requests()
    end

    test "keeps the operation's own filters on every page" do
      module = paging_client([[%{"n" => 1}]])
      query = Query.new(filters: [{"Customer", :eq, "1"}])

      assert {:ok, 1} =
               module.stream(get("/A_Customer", query: query, page_size: 2), 0, &(&2 + length(&1)))

      assert [%{query: %{"$filter" => "Customer eq '1'"}}] = received_requests()
    end

    test "a failed page fails the stream" do
      module = respond(500, %{})

      assert {:error, %Error{kind: :http}} = module.stream(get("/A_Customer"), [], &(&2 ++ &1))
    end

    test "reaching max_pages is :truncated, never partial results" do
      module = paging_client([[%{"n" => 1}], [%{"n" => 2}], [%{"n" => 3}]])
      operation = get("/A_Customer", page_size: 1, max_pages: 2)

      assert {:error, %Error{kind: :truncated, message: message}} =
               module.stream(operation, [], &(&2 ++ &1))

      assert message =~ ":max_pages (2)"
    end
  end
end
