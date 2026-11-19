defmodule Sap.Client do
  @moduledoc """
  Defines a connection to one SAP system, in the style of `Ecto.Repo`.

      defmodule MyApp.Sap do
        use Sap.Client, otp_app: :my_app
      end

  Configure it under your own OTP app:

      config :my_app, MyApp.Sap,
        base_url: "https://sap.example.com",
        sap_client: "110",
        user: System.fetch_env!("SAP_USER"),
        password: System.fetch_env!("SAP_PASSWORD")

  Add it to your supervision tree:

      children = [MyApp.Sap]

  Then run operations through it:

      %Sap.Customers.Params.Get{customer: "100001"}
      |> Sap.Customers.get()
      |> MyApp.Sap.request()

  An app that talks to several SAP systems defines one module per system (`MyApp.SapQA`,
  `MyApp.SapProd`). Each has its own configuration, process and CSRF tokens; nothing is shared.

  ## Configuration

    * `:base_url` - required. The SAP origin, for example `"https://sap.example.com"`.
    * `:sap_client` - required. The SAP client (mandant), sent as the `sap-client` header.
    * `:user`, `:password` - required. Basic auth credentials.
    * `:receive_timeout` - milliseconds to wait for a response. Default `60_000`.
    * `:csrf_refresh_interval` - milliseconds between CSRF token refreshes. Default 15 minutes.
      Set it below the SAP system's session timeout. Refresh cannot be switched off.
    * `:csrf_timeout` - milliseconds to wait for a CSRF token fetch. Default `15_000`.
    * `:req_options` - options merged into every `Req` request: TLS settings, a test `:plug`,
      or `retry:` for reads (see below). Used by the default adapter only.
    * `:adapter` - the HTTP client that sends requests: a module implementing
      `Sap.HTTP.Adapter`, or `{module, options}`. Default `Sap.HTTP.ReqAdapter`.

  Configuration is read once, when the client starts: the application environment, then the
  options given to `start_link/1`, then the `c:init/1` callback. Invalid configuration stops the
  client from starting.

  ## The client process

  Starting a client stores its configuration (in `:persistent_term`) and starts one process that
  keeps a CSRF token ready for every SAP service the library writes to. The process fetches the
  tokens on boot and refreshes them on a timer. Requests run in the calling process and read the
  configuration and token directly, so the client process is never a bottleneck.

  A client must be started before any request. Until then, and again after it is stopped, every
  call returns `{:error, %Sap.Error{kind: :not_started}}`. If the process crashes, reads still
  work while the supervisor restarts it; writes return `:not_started` until it is back.

  ## Retries

  The library does not retry. That policy belongs to your application: see `Sap.Error` for which
  failures leave a write's outcome unknown.

  To retry reads at the HTTP level, pass Req's option in `:req_options`, for example
  `req_options: [retry: :safe_transient]`. Retries are always disabled for writes, whatever
  `:req_options` says. A custom `Sap.HTTP.Adapter` must follow the same rule.

  The one exception to "no retries" is the CSRF handshake: when SAP rejects a write because its
  token is stale, SAP has not processed the request, so the client fetches a new token and sends
  the request once more.

  ## Testing

  Start the client in the test with a plug in place of the network:

      start_supervised!({MyApp.Sap, req_options: [plug: &MyApp.SapStub.call/1]})

  The plug also receives the CSRF token fetches the client process makes on boot, from a process
  other than the test's. A plain function plug works from any process. A `Req.Test` stub needs
  `Req.Test.set_req_test_to_shared/1`.
  """

  alias Sap.Batch
  alias Sap.Client.Config
  alias Sap.Client.Server
  alias Sap.Error
  alias Sap.HTTP
  alias Sap.Odata.Query
  alias Sap.Operation

  @call_timeout 30_000

  @doc """
  Adjusts the configuration when the client starts.

  Receives the options from the application environment merged with those given to `start_link/1`
  and returns `{:ok, options}`. Use it for values only known at runtime.
  """
  @callback init(options :: keyword()) :: {:ok, keyword()}

  @doc "The client's validated configuration."
  @callback config() :: {:ok, Config.t()} | {:error, Error.t()}

  @doc """
  Runs an operation or a batch.

  An operation returns `{:ok, result}`, where the result is the decoded struct, a list of them,
  or `nil` for an operation with nothing to return. A `Sap.Batch` returns
  `{:ok, %Sap.Batch.Response{}}`.
  """
  @callback request(Operation.t() | Batch.t()) :: {:ok, term()} | {:error, Error.t()}

  @doc """
  Pages through a collection operation, folding each page through `reducer.(rows, acc)`.

  Re-issues the operation with a rising `$skip` of the operation's `:page_size`, stopping at the
  first page shorter than that. A failed page fails the whole call. Reaching the operation's
  `:max_pages` returns `{:error, %Sap.Error{kind: :truncated}}` rather than partial results.
  """
  @callback stream(Operation.t(), acc, (list(), acc -> acc)) :: {:ok, acc} | {:error, Error.t()}
            when acc: term()

  defmacro __using__(options) do
    otp_app = Keyword.fetch!(options, :otp_app)

    quote do
      @behaviour Sap.Client

      @doc false
      def child_spec(options) do
        %{id: __MODULE__, start: {__MODULE__, :start_link, [options]}, type: :worker}
      end

      @doc false
      def start_link(options \\ []),
        do: Sap.Client.start_link(__MODULE__, unquote(otp_app), options)

      @impl Sap.Client
      def init(options), do: {:ok, options}

      @impl Sap.Client
      def config, do: Sap.Client.config(__MODULE__)

      @impl Sap.Client
      def request(operation), do: Sap.Client.request(__MODULE__, operation)

      @impl Sap.Client
      def stream(operation, acc, reducer),
        do: Sap.Client.stream(__MODULE__, operation, acc, reducer)

      defoverridable init: 1, child_spec: 1
    end
  end

  @doc false
  @spec start_link(module(), atom(), keyword()) :: GenServer.on_start()
  def start_link(module, otp_app, options), do: Server.start_link(module, otp_app, options)

  @doc "The validated configuration of the client `module`."
  @spec config(module()) :: {:ok, Config.t()} | {:error, Error.t()}
  def config(module) do
    case :persistent_term.get(Server.config_key(module), nil) do
      %Config{} = config -> {:ok, config}
      nil -> {:error, Error.new(:not_started)}
    end
  end

  @doc "Runs an operation or a batch through the client `module`. See `c:request/1`."
  @spec request(module(), Operation.t() | Batch.t()) :: {:ok, term()} | {:error, Error.t()}
  def request(module, %Operation{} = operation) do
    with {:ok, config} <- config(module), do: HTTP.run(module, config, operation)
  end

  def request(module, %Batch{} = batch) do
    with {:ok, config} <- config(module), do: HTTP.run_batch(module, config, batch)
  end

  @doc "Pages through a collection operation through the client `module`. See `c:stream/3`."
  @spec stream(module(), Operation.t(), acc, (list(), acc -> acc)) ::
          {:ok, acc} | {:error, Error.t()}
        when acc: term()
  def stream(module, %Operation{} = operation, acc, reducer) when is_function(reducer, 2),
    do: page(module, operation, acc, reducer, 0)

  defp page(_module, %Operation{max_pages: max} = operation, _acc, _reducer, index)
       when index >= max do
    {:error,
     Error.new(:truncated,
       service: operation.service,
       message: "paging stopped at :max_pages (#{max}); partial results were refused"
     )}
  end

  defp page(module, %Operation{page_size: size} = operation, acc, reducer, index) do
    case request(module, paged(operation, size, index * size)) do
      {:ok, rows} when is_list(rows) and length(rows) < size ->
        {:ok, reducer.(rows, acc)}

      {:ok, rows} when is_list(rows) ->
        page(module, operation, reducer.(rows, acc), reducer, index + 1)

      {:error, %Error{}} = error ->
        error
    end
  end

  defp paged(operation, size, skip) do
    %{
      operation
      | shape: :collection,
        truncation: :ignore,
        query: with_paging(operation.query, size, skip)
    }
  end

  defp with_paging(%Query{} = query, size, skip), do: query |> Query.top(size) |> Query.skip(skip)
  defp with_paging(nil, size, skip), do: Query.new() |> Query.top(size) |> Query.skip(skip)

  defp with_paging(params, size, skip) when is_list(params),
    do: params ++ [{"$top", Integer.to_string(size)}, {"$skip", Integer.to_string(skip)}]

  # ── CSRF sessions ───────────────────────────────────────────────────────────

  @doc false
  # The cached CSRF session for `service`: an ETS read in the calling process. Only a miss
  # reaches the client process, which answers once the fetch in flight completes.
  @spec session(module(), Operation.service()) :: {:ok, Server.session()} | {:error, Error.t()}
  def session(module, service) do
    case Server.cached(module, service) do
      {:ok, session} -> {:ok, session}
      :miss -> call(module, {:acquire, service}, service)
    end
  end

  @doc false
  # Replaces a session SAP rejected. If another caller already replaced that generation, its
  # session is returned instead of fetching again.
  @spec rotate(module(), Operation.service(), pos_integer()) ::
          {:ok, Server.session()} | {:error, Error.t()}
  def rotate(module, service, generation),
    do: call(module, {:rotate, service, generation}, service)

  defp call(module, message, service) do
    GenServer.call(module, message, @call_timeout)
  catch
    :exit, {:timeout, _call} ->
      {:error, Error.new(:csrf, service: service, message: "timed out waiting for a CSRF token")}

    :exit, _not_running ->
      {:error, Error.new(:not_started, service: service)}
  end
end
