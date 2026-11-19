defmodule Sap.ClientTest do
  use Sap.ApiCase, async: true

  alias Sap.Client.Config
  alias Sap.Error
  alias Sap.Operation

  @valid [base_url: "https://sap.test", sap_client: "110", user: "user", password: "secret"]

  describe "Config.new!/1" do
    test "names a missing required key" do
      for key <- [:base_url, :sap_client, :user, :password] do
        assert_raise ArgumentError, ~r/missing required SAP client option #{inspect(key)}/, fn ->
          Config.new!(Keyword.delete(@valid, key))
        end
      end
    end

    test "rejects unknown keys, bad timeouts and bad URLs" do
      assert_raise ArgumentError, ~r/unknown SAP client option :usr/, fn ->
        Config.new!(@valid ++ [usr: "x"])
      end

      assert_raise ArgumentError, ~r/:receive_timeout must be a positive integer/, fn ->
        Config.new!(@valid ++ [receive_timeout: 0])
      end

      assert_raise ArgumentError, ~r/:base_url must be an http\(s\) URL/, fn ->
        Config.new!(Keyword.put(@valid, :base_url, "sap.test"))
      end

      assert_raise ArgumentError, ~r/:req_options must be a keyword list/, fn ->
        Config.new!(@valid ++ [req_options: %{}])
      end
    end

    test "keeps only the origin of the base URL and applies defaults" do
      config = Config.new!(Keyword.put(@valid, :base_url, "https://sap.test:8443/sap/opu/odata"))

      assert config.base_url == "https://sap.test:8443"
      assert config.receive_timeout == 60_000
      assert config.csrf_refresh_interval == 900_000
    end

    test "never shows the password when inspected" do
      refute inspect(Config.new!(@valid)) =~ "secret"
    end
  end

  describe "a client module" do
    test "does not start with invalid configuration, and says why" do
      module = define_client()

      assert {:error, {%ArgumentError{message: message}, _child}} =
               start_supervised({module, Keyword.delete(@valid, :password)})

      assert message =~ ":password"
    end

    test "returns :not_started before it has ever been started" do
      module = define_client()

      assert {:error, %Error{kind: :not_started}} = module.config()

      assert {:error, %Error{kind: :not_started}} =
               module.request(%Operation{service: "API_BUSINESS_PARTNER", path: "/A_Customer"})
    end

    test "exposes its validated configuration once started" do
      module = start_client(fn conn, _request -> json(conn, %{}) end, sap_client: "220")

      assert {:ok, %Config{sap_client: "220", base_url: "https://sap.test"}} = module.config()
    end

    test "two clients hold separate configuration" do
      qa = start_client(fn conn, _request -> json(conn, %{}) end, sap_client: "110")
      prod = start_client(fn conn, _request -> json(conn, %{}) end, sap_client: "100")

      assert {:ok, %Config{sap_client: "110"}} = qa.config()
      assert {:ok, %Config{sap_client: "100"}} = prod.config()
    end

    test "init/1 can change the configuration at start" do
      module =
        define_client(
          quote do
            def init(options), do: {:ok, Keyword.put(options, :sap_client, "999")}
          end
        )

      start_supervised!({module, @valid ++ [req_options: [plug: fn conn -> json(conn, %{}) end]]})

      assert {:ok, %Config{sap_client: "999"}} = module.config()
    end

    test "an init/1 that returns something else stops the client from starting" do
      module =
        define_client(
          quote do
            def init(_options), do: :nope
          end
        )

      assert {:error, {%ArgumentError{message: message}, _child}} =
               start_supervised({module, @valid})

      assert message =~ "init/1 must return {:ok, keyword}"
    end

    test "is not started again once it has been stopped" do
      module =
        start_client(fn conn, _request -> json(conn, %{"d" => %{"Customer" => "1"}}) end)

      assert {:ok, %Config{}} = module.config()
      :ok = stop_supervised(module)

      assert {:error, %Error{kind: :not_started}} = module.config()

      assert {:error, %Error{kind: :not_started}} =
               module.request(%Operation{service: "API_BUSINESS_PARTNER", path: "/A_Customer('1')"})

      assert {:error, %Error{kind: :not_started}} =
               module.request(%Operation{service: "API_SALES_ORDER_SRV", method: :post, body: %{}})
    end

    test "a stopped client can be started again with different configuration" do
      module = start_client(fn conn, _request -> json(conn, %{}) end, sap_client: "110")
      :ok = stop_supervised(module)

      start_supervised!(
        {module,
         base_url: "https://sap.test",
         sap_client: "220",
         user: "user",
         password: "secret",
         req_options: [plug: fn conn -> json(conn, %{}) end]}
      )

      assert {:ok, %Config{sap_client: "220"}} = module.config()
    end

    @tag :capture_log
    test "keeps its configuration when a callback raises" do
      module = define_client()

      {:ok, pid} =
        GenServer.start(
          Sap.Client.Server,
          {module, :sap,
           base_url: "https://sap.test",
           sap_client: "110",
           user: "user",
           password: "secret",
           req_options: [plug: fn conn -> json(conn, %{}) end]},
          name: module
        )

      await_idle(module)
      ref = Process.monitor(pid)
      catch_exit(GenServer.call(module, :not_a_message))
      assert_receive {:DOWN, ^ref, :process, ^pid, _crash}

      assert {:ok, %Config{}} = module.config()
    end

    test "keeps serving reads after a crash, until it is restarted" do
      module = define_client()
      plug = fn conn -> json(conn, %{"d" => %{"Customer" => "1"}}) end

      # Started outside a supervisor so nothing restarts it.
      {:ok, pid} =
        GenServer.start(
          Sap.Client.Server,
          {module, :sap,
           base_url: "https://sap.test",
           sap_client: "110",
           user: "user",
           password: "secret",
           req_options: [plug: plug]},
          name: module
        )

      await_idle(module)
      ref = Process.monitor(pid)
      Process.exit(pid, :kill)
      assert_receive {:DOWN, ^ref, :process, ^pid, :killed}

      assert {:ok, %Config{}} = module.config()

      assert {:ok, %{"Customer" => "1"}} =
               module.request(%Operation{service: "API_BUSINESS_PARTNER", path: "/A_Customer('1')"})

      assert {:error, %Error{kind: :not_started}} =
               module.request(%Operation{service: "API_SALES_ORDER_SRV", method: :post, body: %{}})
    end
  end
end
