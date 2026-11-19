defmodule Sap.Client.Server do
  @moduledoc false

  # The process behind one client module. It does three things:
  #
  #   1. On boot, resolves and validates the client's configuration and stores it in
  #      `:persistent_term`. Config never changes after boot, so reads are free. It survives a
  #      crash of this process, so reads keep working until the supervisor restarts it, and is
  #      erased when the process stops in an orderly way, so a stopped client is not started.
  #   2. Owns the ETS table of CSRF sessions (token + cookies), one row per SAP service. Callers
  #      read the table directly; only this process writes it.
  #   3. Keeps those sessions fresh: a fetch for every writable service on boot, then again on a
  #      timer for as long as it runs.
  #
  # Fetches run in monitored helper processes, never in this one, so a slow SAP cannot block a
  # caller that needs this process for something else. A caller that finds no token (boot fetch
  # still in flight, or failed) waits here for the fetch in flight; concurrent misses share it.

  use GenServer

  alias Sap.Client.Config
  alias Sap.Error
  alias Sap.HTTP

  @type session :: %{token: String.t(), cookies: map(), generation: pos_integer()}

  @doc "The SAP services the library can write to. Their CSRF tokens are fetched on boot."
  @spec csrf_services() :: [String.t()]
  def csrf_services, do: [Sap.SalesOrders.service()]

  @doc "The name of the ETS table holding `module`'s CSRF sessions."
  @spec table(module()) :: atom()
  def table(module), do: Module.concat(module, "CsrfSessions")

  @doc "The `:persistent_term` key holding `module`'s config."
  @spec config_key(module()) :: term()
  def config_key(module), do: {Sap.Client, module}

  @spec start_link(module(), atom(), keyword()) :: GenServer.on_start()
  def start_link(module, otp_app, options),
    do: GenServer.start_link(__MODULE__, {module, otp_app, options}, name: module)

  # ── server ──────────────────────────────────────────────────────────────────

  @impl GenServer
  def init({module, otp_app, options}) do
    case resolve(module, otp_app, options) do
      {:ok, %Config{} = config} ->
        # Trapped so `terminate/2` runs when the supervisor stops this process.
        Process.flag(:trap_exit, true)
        :persistent_term.put(config_key(module), config)
        :ets.new(table(module), [:named_table, :protected, :set, read_concurrency: true])

        state = %{
          module: module,
          config: config,
          services: MapSet.new(csrf_services()),
          generations: %{},
          fetching: %{}
        }

        {:ok, state, {:continue, :boot}}

      {:error, %ArgumentError{} = error} ->
        {:stop, error}
    end
  end

  defp resolve(module, otp_app, options) do
    merged = otp_app |> Application.get_env(module, []) |> Keyword.merge(options)

    case module.init(merged) do
      {:ok, resolved} when is_list(resolved) ->
        {:ok, Config.new!(resolved)}

      other ->
        raise ArgumentError,
              "#{inspect(module)}.init/1 must return {:ok, keyword}, got: #{inspect(other)}"
    end
  rescue
    error in ArgumentError -> {:error, error}
  end

  @impl GenServer
  def handle_continue(:boot, state), do: {:noreply, state |> fetch_all() |> schedule_refresh()}

  @impl GenServer
  def handle_call({:acquire, service}, from, state) do
    case cached(state.module, service) do
      {:ok, session} -> {:reply, {:ok, session}, state}
      :miss -> {:noreply, state |> fetch(service) |> add_waiter(service, from)}
    end
  end

  def handle_call({:rotate, service, seen}, from, state) do
    case cached(state.module, service) do
      # Another caller already replaced the generation this caller saw.
      {:ok, %{generation: generation} = session} when generation > seen ->
        {:reply, {:ok, session}, state}

      _stale_or_missing ->
        # Drop the row first: the fast path must not hand out a token known to be dead.
        :ets.delete(table(state.module), service)
        {:noreply, state |> fetch(service) |> add_waiter(service, from)}
    end
  end

  @impl GenServer
  def handle_info(:refresh, state), do: {:noreply, state |> fetch_all() |> schedule_refresh()}

  def handle_info({:DOWN, ref, :process, _pid, reason}, state) do
    case Enum.find(state.fetching, fn {_service, entry} -> entry.ref == ref end) do
      nil -> {:noreply, state}
      {service, entry} -> {:noreply, fulfilled(state, service, entry, result(reason, service))}
    end
  end

  def handle_info(_message, state), do: {:noreply, state}

  # An orderly stop removes the configuration: a stopped client must answer `:not_started`, not
  # serve reads with what it was last configured with. A crash leaves it in place for the restart.
  @impl GenServer
  def terminate(reason, state) do
    if orderly?(reason), do: :persistent_term.erase(config_key(state.module))
    :ok
  end

  defp orderly?(:normal), do: true
  defp orderly?(:shutdown), do: true
  defp orderly?({:shutdown, _detail}), do: true
  defp orderly?(_crash), do: false

  # ── fetching ────────────────────────────────────────────────────────────────

  defp fetch_all(state), do: Enum.reduce(state.services, state, &fetch(&2, &1))

  defp fetch(state, service) when is_map_key(state.fetching, service), do: state

  defp fetch(state, service) do
    config = state.config
    callers = [self() | Process.get(:"$callers", [])]

    # The result travels in the exit reason, so one `:DOWN` message covers both a finished fetch
    # and a crashed one.
    {_pid, ref} =
      spawn_monitor(fn ->
        Process.put(:"$callers", callers)
        exit({:csrf_result, HTTP.fetch_csrf(config, service)})
      end)

    %{
      state
      | services: MapSet.put(state.services, service),
        fetching: Map.put(state.fetching, service, %{ref: ref, waiters: []})
    }
  end

  defp result({:csrf_result, {:ok, %{token: _, cookies: _}} = ok}, _service), do: ok
  defp result({:csrf_result, {:error, %Error{}} = error}, _service), do: error

  defp result(reason, service),
    do:
      {:error,
       Error.new(:csrf, service: service, reason: reason, message: "the CSRF token fetch crashed")}

  defp fulfilled(state, service, entry, {:ok, fetched}) do
    generation = Map.get(state.generations, service, 0) + 1
    session = Map.put(fetched, :generation, generation)

    :ets.insert(table(state.module), {service, session})
    Enum.each(entry.waiters, &GenServer.reply(&1, {:ok, session}))

    %{
      state
      | fetching: Map.delete(state.fetching, service),
        generations: Map.put(state.generations, service, generation)
    }
  end

  # A failed fetch stores nothing. A token already in the table stays: it may still be valid, and
  # the next refresh or a `403 Required` will replace it.
  defp fulfilled(state, service, entry, {:error, %Error{}} = error) do
    Enum.each(entry.waiters, &GenServer.reply(&1, error))
    %{state | fetching: Map.delete(state.fetching, service)}
  end

  defp add_waiter(state, service, from),
    do: update_in(state, [:fetching, service, :waiters], &[from | &1])

  defp schedule_refresh(state) do
    Process.send_after(self(), :refresh, state.config.csrf_refresh_interval)
    state
  end

  @doc "Reads `module`'s cached session for `service` straight from ETS."
  @spec cached(module(), String.t()) :: {:ok, session()} | :miss
  def cached(module, service) do
    case :ets.lookup(table(module), service) do
      [{^service, session}] -> {:ok, session}
      [] -> :miss
    end
  rescue
    # The table does not exist: the client was never started, or is restarting.
    ArgumentError -> :miss
  end
end
