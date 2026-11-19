defmodule Sap.AdapterTest do
  use Sap.ApiCase, async: true

  alias Sap.Client.Config
  alias Sap.Error
  alias Sap.HTTP.ReqAdapter
  alias Sap.HTTP.Request
  alias Sap.HTTP.Response
  alias Sap.Operation

  defmodule Custom do
    @moduledoc false
    @behaviour Sap.HTTP.Adapter

    # Reports each request to the test and answers with whatever `:respond` returns.
    @impl true
    def request(%Request{} = request, options) do
      send(options[:test], {:adapter, request, options})
      options[:respond].(request)
    end
  end

  defmodule NoOptions do
    @moduledoc false
    @behaviour Sap.HTTP.Adapter

    @impl true
    def request(%Request{}, []), do: {:ok, %Response{status: 200, body: ~s({"d":{"Customer":"1"}})}}
  end

  @valid [base_url: "https://sap.test", sap_client: "110", user: "user", password: "secret"]

  defp csrf_fetch?(%Request{headers: headers}), do: {"x-csrf-token", "Fetch"} in headers

  defp start(respond) do
    module = define_client()
    test = self()

    respond = fn request ->
      if csrf_fetch?(request) do
        {:ok,
         %Response{
           status: 200,
           headers: [{"X-CSRF-Token", "tok"}, {"Set-Cookie", "a=1; path=/"}, {"set-cookie", "b=2"}]
         }}
      else
        respond.(request)
      end
    end

    start_supervised!(
      {module, @valid ++ [adapter: {Custom, test: test, respond: respond, pool: :sap}]}
    )

    await_idle(module)
    module
  end

  defp requests(acc \\ []) do
    receive do
      {:adapter, request, _options} -> requests([request | acc])
    after
      0 -> acc |> Enum.reverse() |> Enum.reject(&csrf_fetch?/1)
    end
  end

  defp get, do: %Operation{service: "API_BUSINESS_PARTNER", path: "/A_Customer('1')"}

  defp post,
    do: %Operation{
      service: "API_SALES_ORDER_SRV",
      method: :post,
      path: "/A_SalesOrder",
      body: %{"A" => "1"}
    }

  describe "configuration" do
    test "the default adapter is Req, carrying :req_options" do
      assert %Config{adapter: {ReqAdapter, []}} = Config.new!(@valid)

      assert %Config{adapter: {ReqAdapter, [retry: :safe_transient]}} =
               Config.new!(@valid ++ [req_options: [retry: :safe_transient]])
    end

    test "accepts a module, or a module with options" do
      assert %Config{adapter: {NoOptions, []}} = Config.new!(@valid ++ [adapter: NoOptions])

      assert %Config{adapter: {Custom, [pool: :sap]}} =
               Config.new!(@valid ++ [adapter: {Custom, pool: :sap}])
    end

    test "rejects anything that does not implement the behaviour" do
      for bad <- [
            String,
            Sap.NoSuchAdapter,
            "Custom",
            {Custom, :not_a_keyword},
            {Custom, [1, 2]},
            nil
          ] do
        assert_raise ArgumentError,
                     ~r/:adapter must be a module implementing Sap.HTTP.Adapter/,
                     fn ->
                       Config.new!(@valid ++ [adapter: bad])
                     end
      end
    end
  end

  describe "a custom adapter" do
    test "receives the fully built request and its own options" do
      module =
        start(fn _request -> {:ok, %Response{status: 200, body: ~s({"d":{"Customer":"1"}})}} end)

      assert {:ok, %{"Customer" => "1"}} = module.request(%{get() | receive_timeout: 1_234})

      assert_received {:adapter, %Request{method: :get} = request, options}
                      when request.receive_timeout == 1_234

      assert request.url ==
               "https://sap.test/sap/opu/odata/sap/API_BUSINESS_PARTNER/A_Customer('1')"

      assert {"Authorization", "Basic " <> Base.encode64("user:secret")} in request.headers
      assert {"sap-client", "110"} in request.headers
      assert request.body == nil
      assert options[:pool] == :sap
    end

    test "may return a JSON body already decoded" do
      module =
        start(fn _request ->
          {:ok, %Response{status: 200, body: %{"d" => %{"Customer" => "1"}}}}
        end)

      assert {:ok, %{"Customer" => "1"}} = module.request(get())
    end

    test "serves the CSRF fetch, and a write carries the token and every cookie it returned" do
      module =
        start(fn _request -> {:ok, %Response{status: 201, body: ~s({"d":{"SalesOrder":"9"}})}} end)

      assert {:ok, %{"SalesOrder" => "9"}} = module.request(post())

      assert [%Request{method: :post} = write] = requests()
      assert {"x-csrf-token", "tok"} in write.headers
      assert {"Cookie", "a=1; b=2"} in write.headers
      assert {"Content-Type", "application/json"} in write.headers
      assert write.body == ~s({"A":"1"})
    end

    test "a non-2xx response is classified by the library" do
      module =
        start(fn _request ->
          {:ok, %Response{status: 404, body: ~s({"error":{"code":"X","message":{"value":"Nope"}}})}}
        end)

      assert {:error, %Error{kind: :not_found, code: "X", message: "Nope"}} = module.request(get())
    end

    test "a stale-token rejection is rotated and resent once, with header names in any case" do
      {:ok, writes} = Agent.start_link(fn -> 0 end)

      module =
        start(fn _request ->
          case Agent.get_and_update(writes, &{&1, &1 + 1}) do
            0 -> {:ok, %Response{status: 403, headers: [{"X-Csrf-Token", "Required"}]}}
            _ -> {:ok, %Response{status: 201, body: ~s({"d":{"SalesOrder":"9"}})}}
          end
        end)

      assert {:ok, %{"SalesOrder" => "9"}} = module.request(post())
      assert [_first, _second] = requests()
    end

    test "{:error, :timeout} is :timeout and any other error is :transport" do
      slow = start(fn _request -> {:error, :timeout} end)
      assert {:error, %Error{kind: :timeout, reason: :timeout}} = slow.request(get())

      down = start(fn _request -> {:error, :econnrefused} end)
      assert {:error, %Error{kind: :transport, reason: :econnrefused}} = down.request(get())
    end

    test "a return value outside the behaviour is a :transport error, not a crash" do
      module = start(fn _request -> {:ok, %{status: 200}} end)

      assert {:error,
              %Error{kind: :transport, reason: {:bad_adapter_return, {:ok, %{status: 200}}}}} =
               module.request(get())
    end

    test "configured as a bare module, it is called with no options" do
      module = define_client()
      start_supervised!({module, @valid ++ [adapter: NoOptions]})

      assert {:ok, %{"Customer" => "1"}} = module.request(get())
    end
  end

  describe "Sap.HTTP.Request" do
    test "inspect shows neither headers nor body" do
      request = %Request{
        method: :post,
        url: "https://sap.test/x",
        receive_timeout: 1,
        headers: [{"Authorization", "Basic c2VjcmV0"}],
        body: "customer data"
      }

      refute inspect(request) =~ "c2VjcmV0"
      refute inspect(request) =~ "customer data"
    end
  end

  describe "Sap.HTTP.ReqAdapter" do
    defp req(request, options), do: ReqAdapter.request(request, options)

    test "returns one header pair per value and does not follow redirects" do
      plug = fn conn ->
        conn
        |> Plug.Conn.prepend_resp_headers([
          {"set-cookie", "a=1"},
          {"set-cookie", "b=2"},
          {"location", "/elsewhere"}
        ])
        |> Plug.Conn.send_resp(302, "")
      end

      request = %Request{method: :get, url: "https://sap.test/x", receive_timeout: 1_000}

      assert {:ok, %Response{status: 302} = response} = req(request, plug: plug)
      assert Enum.sort(Response.header(response, "set-cookie")) == ["a=1", "b=2"]
    end

    test "maps a Req timeout to :timeout and passes other failures through" do
      request = %Request{method: :get, url: "https://sap.test/x", receive_timeout: 1_000}

      assert {:error, :timeout} = req(request, plug: &Req.Test.transport_error(&1, :timeout))

      assert {:error, %Req.TransportError{reason: :econnrefused}} =
               req(request, plug: &Req.Test.transport_error(&1, :econnrefused))
    end
  end
end
