defmodule Sap.CsrfTest do
  use Sap.ApiCase, async: true

  alias Sap.Error
  alias Sap.Operation

  @service "API_SALES_ORDER_SRV"

  defp post,
    do: %Operation{service: @service, method: :post, path: "/A_SalesOrder", body: %{"A" => "1"}}

  defp created(conn, _request), do: json(conn, 201, %{"d" => %{"SalesOrder" => "1"}})

  # A counter the plug can bump from whichever process runs it.
  defp counter do
    {:ok, agent} = Agent.start_link(fn -> 0 end)
    agent
  end

  defp bump(agent), do: Agent.get_and_update(agent, &{&1 + 1, &1 + 1})

  defp token_response(conn, token) do
    conn
    |> Plug.Conn.put_resp_header("x-csrf-token", token)
    |> Plug.Conn.put_resp_header("set-cookie", "SAP_SESSIONID=#{token}-cookie; path=/")
    |> json(%{"d" => %{}})
  end

  describe "on boot" do
    test "fetches a token for the sales order service from the service root" do
      start_client(&created/2)

      assert_receive {:sap, %{csrf_fetch?: true} = fetch}
      assert fetch.method == "GET"
      assert fetch.path == root() <> "/API_SALES_ORDER_SRV/"
      assert fetch.query == %{"$format" => "json"}
      assert fetch.headers["authorization"] == "Basic " <> Base.encode64("user:secret")
      assert fetch.headers["sap-client"] == "110"
    end

    test "the first write uses the boot token and its cookies without fetching again" do
      module = start_client(&created/2, csrf: fn conn, _ -> token_response(conn, "boot") end)
      await_boot()

      assert {:ok, %{"SalesOrder" => "1"}} = module.request(post())

      assert [write] = received_requests()
      assert write.headers["x-csrf-token"] == "boot"
      assert write.headers["cookie"] == "SAP_SESSIONID=boot-cookie"
      assert write.headers["content-type"] == "application/json"
      assert write.json == %{"A" => "1"}
      assert received_csrf_fetches() == []
    end

    test "the client starts even when SAP is unreachable, and the next write fetches on demand" do
      fetches = counter()

      csrf = fn conn, _request ->
        case bump(fetches) do
          1 -> Req.Test.transport_error(conn, :econnrefused)
          _ -> token_response(conn, "late")
        end
      end

      module = start_client(&created/2, csrf: csrf)
      await_boot()

      assert {:ok, _order} = module.request(post())
      assert [%{headers: %{"x-csrf-token" => "late"}}] = received_requests()
    end

    test "a write fails with :csrf when no token can be fetched, and nothing is posted" do
      module =
        start_client(&created/2, csrf: fn conn, _ -> json(conn, 503, %{}) end)

      await_boot()

      assert {:error, %Error{kind: :csrf, status: 503, service: @service}} = module.request(post())
      assert received_requests() == []
    end

    test "a fetch that returns no token header is :csrf" do
      module = start_client(&created/2, csrf: fn conn, _ -> json(conn, %{"d" => %{}}) end)
      await_boot()

      assert {:error, %Error{kind: :csrf, message: "SAP returned no x-csrf-token header"}} =
               module.request(post())
    end

    @tag :capture_log
    test "a fetch that crashes is reported as :csrf, and the client keeps running" do
      module = start_client(&created/2, csrf: fn _conn, _ -> raise "boom" end)
      await_boot()

      assert {:error, %Error{kind: :csrf}} = module.request(post())

      assert is_pid(Process.whereis(module))
    end
  end

  describe "refresh" do
    test "replaces the token on a timer for as long as the client runs" do
      fetches = counter()
      csrf = fn conn, _request -> token_response(conn, "t#{bump(fetches)}") end
      module = start_client(&created/2, csrf: csrf, csrf_refresh_interval: 20)

      await_boot()
      assert_receive {:sap, %{csrf_fetch?: true}}, 1_000
      assert_receive {:sap, %{csrf_fetch?: true}}, 1_000
      received_csrf_fetches()

      assert {:ok, _order} = module.request(post())
      assert [%{headers: %{"x-csrf-token" => "t" <> n}}] = received_requests()
      assert String.to_integer(n) > 1
    end

    test "a failed refresh keeps the token it already has" do
      fetches = counter()

      csrf = fn conn, _request ->
        case bump(fetches) do
          1 -> token_response(conn, "first")
          _ -> json(conn, 500, %{})
        end
      end

      module = start_client(&created/2, csrf: csrf, csrf_refresh_interval: 20)
      await_boot()
      assert_receive {:sap, %{csrf_fetch?: true}}, 1_000
      await_idle(module)

      assert {:ok, _order} = module.request(post())
      assert [%{headers: %{"x-csrf-token" => "first"}}] = received_requests()
    end
  end

  describe "a stale token" do
    defp stale_then_created(writes) do
      fn conn, _request ->
        case bump(writes) do
          1 -> conn |> Plug.Conn.put_resp_header("x-csrf-token", "Required") |> json(403, %{})
          _ -> json(conn, 201, %{"d" => %{"SalesOrder" => "1"}})
        end
      end
    end

    test "is rotated once and the write is sent once more" do
      fetches = counter()
      csrf = fn conn, _request -> token_response(conn, "t#{bump(fetches)}") end
      module = start_client(stale_then_created(counter()), csrf: csrf)
      await_boot()

      assert {:ok, %{"SalesOrder" => "1"}} = module.request(post())

      assert [first, second] = received_requests()
      assert first.headers["x-csrf-token"] == "t1"
      assert second.headers["x-csrf-token"] == "t2"
      assert second.headers["cookie"] == "SAP_SESSIONID=t2-cookie"
      assert second.json == first.json
    end

    test "that is still rejected after rotation returns :csrf after exactly two writes" do
      required = fn conn, _request ->
        conn |> Plug.Conn.put_resp_header("x-csrf-token", "required") |> json(403, %{})
      end

      module = start_client(required)
      await_boot()

      assert {:error, %Error{kind: :csrf, status: 403}} = module.request(post())
      assert [_first, _second] = received_requests()
    end

    test "is rotated once however many writers hit it together" do
      test = self()
      fetches = counter()

      csrf = fn conn, _request ->
        n = bump(fetches)
        # Hold the rotation open so every writer is waiting on the same fetch.
        if n == 2, do: Process.sleep(100)
        token_response(conn, "t#{n}")
      end

      handler = fn conn, request ->
        case request.headers["x-csrf-token"] do
          "t1" -> conn |> Plug.Conn.put_resp_header("x-csrf-token", "Required") |> json(403, %{})
          _fresh -> json(conn, 201, %{"d" => %{"SalesOrder" => "1"}})
        end
      end

      module = start_client(handler, csrf: csrf)
      await_boot()

      results =
        1..10
        |> Enum.map(fn _ -> Task.async(fn -> module.request(post()) end) end)
        |> Task.await_many()

      assert Enum.all?(results, &match?({:ok, %{"SalesOrder" => "1"}}, &1))
      assert Agent.get(fetches, & &1) == 2
      assert test == self()
    end
  end

  describe "writes are never retried" do
    test "a write that times out is sent once, even when the host switched retries on" do
      module =
        start_client(fn conn, _request -> Req.Test.transport_error(conn, :timeout) end,
          req_options: [retry: :transient, retry_delay: fn _ -> 1 end, retry_log_level: false]
        )

      await_boot()

      assert {:error, %Error{kind: :timeout, method: :post}} = module.request(post())
      assert [_only_one] = received_requests()
    end

    test "a write that gets a 500 is sent once" do
      module =
        start_client(fn conn, _request -> json(conn, 500, sap_error("SY/530", "Dump")) end,
          req_options: [retry: :transient, retry_delay: fn _ -> 1 end, retry_log_level: false]
        )

      await_boot()

      assert {:error, %Error{kind: :http, status: 500}} = module.request(post())
      assert [_only_one] = received_requests()
    end
  end

  test "two clients never share a token" do
    qa = start_client(&created/2, csrf: fn conn, _ -> token_response(conn, "qa") end)
    await_boot()
    prod = start_client(&created/2, csrf: fn conn, _ -> token_response(conn, "prod") end)
    await_boot()

    assert {:ok, _} = qa.request(post())
    assert {:ok, _} = prod.request(post())

    assert [%{headers: %{"x-csrf-token" => "qa"}}, %{headers: %{"x-csrf-token" => "prod"}}] =
             received_requests()
  end

  test "a service the library does not know to write to gets its token on first use" do
    module = start_client(&created/2)
    await_boot()

    operation = %Operation{service: "API_OTHER_SRV", method: :post, path: "/A_Thing", body: %{}}
    assert {:ok, _} = module.request(operation)

    assert [%{path: path}] = received_csrf_fetches()
    assert path == root() <> "/API_OTHER_SRV/"
  end
end
