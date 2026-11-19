defmodule Sap.Client.Config do
  @moduledoc """
  The validated configuration of one client module. See `Sap.Client` for the keys.

  Built once when the client starts. The password is left out of `inspect/1` output.
  """

  @type t :: %__MODULE__{
          base_url: String.t(),
          sap_client: String.t(),
          user: String.t(),
          password: String.t(),
          receive_timeout: pos_integer(),
          csrf_refresh_interval: pos_integer(),
          csrf_timeout: pos_integer(),
          req_options: keyword(),
          adapter: {module(), keyword()}
        }

  @derive {Inspect, except: [:password]}
  @enforce_keys [:base_url, :sap_client, :user, :password]
  defstruct [
    :base_url,
    :sap_client,
    :user,
    :password,
    receive_timeout: 60_000,
    csrf_refresh_interval: :timer.minutes(15),
    csrf_timeout: 15_000,
    req_options: [],
    adapter: nil
  ]

  @required [:base_url, :sap_client, :user, :password]
  @timeouts [:receive_timeout, :csrf_refresh_interval, :csrf_timeout]
  @known @required ++ @timeouts ++ [:req_options, :adapter]

  @doc """
  Validates `options` into a config, raising `ArgumentError` that names the offending key.

  `:base_url` is reduced to its origin, so a full service URL pasted by mistake still works.

      iex> config = Sap.Client.Config.new!(base_url: "https://sap.example.com/sap/opu", sap_client: "110", user: "u", password: "p")
      iex> config.base_url
      "https://sap.example.com"
  """
  @spec new!(keyword()) :: t()
  def new!(options) when is_list(options) do
    Enum.each(Keyword.keys(options), &known!/1)
    Enum.each(@required, &string!(options, &1))
    Enum.each(@timeouts, &timeout!(options, &1))

    unless Keyword.keyword?(Keyword.get(options, :req_options, [])) do
      raise ArgumentError, "SAP client option :req_options must be a keyword list"
    end

    options
    |> Keyword.update!(:base_url, &origin!/1)
    |> Keyword.put(:adapter, adapter!(options))
    |> then(&struct!(__MODULE__, &1))
  end

  # Normalised to `{module, options}`. The default adapter's options are `:req_options`.
  defp adapter!(options) do
    case Keyword.get(options, :adapter, Sap.HTTP.ReqAdapter) do
      Sap.HTTP.ReqAdapter ->
        {Sap.HTTP.ReqAdapter, Keyword.get(options, :req_options, [])}

      {module, adapter_options} when is_atom(module) and is_list(adapter_options) ->
        adapter!(module, adapter_options)

      module when is_atom(module) and not is_nil(module) ->
        adapter!(module, [])

      _other ->
        bad_adapter!()
    end
  end

  defp adapter!(module, adapter_options) do
    if Keyword.keyword?(adapter_options) and Code.ensure_loaded?(module) and
         function_exported?(module, :request, 2) do
      {module, adapter_options}
    else
      bad_adapter!()
    end
  end

  defp bad_adapter! do
    raise ArgumentError,
          "SAP client option :adapter must be a module implementing Sap.HTTP.Adapter, " <>
            "or {module, keyword}"
  end

  defp known!(key) when key in @known, do: :ok

  defp known!(key) do
    raise ArgumentError,
          "unknown SAP client option #{inspect(key)}; expected one of #{inspect(@known)}"
  end

  defp string!(options, key) do
    case Keyword.get(options, key) do
      value when is_binary(value) and value != "" ->
        :ok

      nil ->
        raise ArgumentError, "missing required SAP client option #{inspect(key)}"

      _other ->
        raise ArgumentError, "SAP client option #{inspect(key)} must be a non-empty string"
    end
  end

  defp timeout!(options, key) do
    case Keyword.fetch(options, key) do
      :error ->
        :ok

      {:ok, value} when is_integer(value) and value > 0 ->
        :ok

      {:ok, _other} ->
        raise ArgumentError,
              "SAP client option #{inspect(key)} must be a positive integer (milliseconds)"
    end
  end

  defp origin!(url) do
    case URI.parse(url) do
      %URI{scheme: scheme, host: host, port: port}
      when scheme in ["http", "https"] and is_binary(host) and host != "" ->
        URI.to_string(%URI{scheme: scheme, host: host, port: port})

      _other ->
        raise ArgumentError,
              "SAP client option :base_url must be an http(s) URL, for example \"https://sap.example.com\""
    end
  end
end
