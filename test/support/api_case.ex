defmodule Sap.ApiCase do
  @moduledoc """
  Test case for anything that talks to SAP through a client.

  `start_client/2` defines a fresh client module, starts it under the test supervisor and routes
  its HTTP through a plug function, so no test touches the network. Every request the client
  makes is also sent to the test process as `{:sap, request}`, including the CSRF token fetches
  the client process makes on its own.
  """

  use ExUnit.CaseTemplate

  using do
    quote do
      import Sap.ApiCase
    end
  end

  @type request :: %{
          method: String.t(),
          path: String.t(),
          query: %{optional(String.t()) => String.t()},
          query_string: String.t(),
          headers: %{optional(String.t()) => String.t()},
          body: String.t(),
          json: term(),
          csrf_fetch?: boolean()
        }

  @root "/sap/opu/odata/sap"

  @doc "The path prefix every service hangs off."
  def root, do: @root

  @doc """
  Starts a client whose requests are answered by `handler.(conn, request)`.

  CSRF token fetches are answered automatically with `token-1`, `token-2`, ... and a session
  cookie, unless `:csrf` is given as a `handler`-shaped function.

  Other options are client configuration (`:csrf_refresh_interval`, `:req_options`, ...).
  """
  def start_client(handler, options \\ []) when is_function(handler, 2) do
    {csrf, options} = Keyword.pop(options, :csrf, &default_csrf/2)
    {req_options, options} = Keyword.pop(options, :req_options, [])
    module = define_client()
    test = self()

    plug = fn conn ->
      {conn, request} = read(conn)
      send(test, {:sap, request})
      if request.csrf_fetch?, do: csrf.(conn, request), else: handler.(conn, request)
    end

    config =
      Keyword.merge(
        [
          base_url: "https://sap.test",
          sap_client: "110",
          user: "user",
          password: "secret",
          req_options: Keyword.merge([plug: plug], req_options)
        ],
        options
      )

    ExUnit.Callbacks.start_supervised!({module, config})
    await_idle(module)
    module
  end

  @doc """
  Blocks until the client process has no CSRF fetch in flight.

  `start_client/2` calls this, so a test starts after the boot fetch has settled either way.
  """
  def await_idle(module, attempts \\ 200) do
    case :sys.get_state(module) do
      %{fetching: fetching} when map_size(fetching) == 0 ->
        :ok

      _busy when attempts > 0 ->
        Process.sleep(5)
        await_idle(module, attempts - 1)

      _busy ->
        raise "the SAP test client never finished fetching its CSRF token"
    end
  end

  @doc "Defines a fresh client module without starting it."
  def define_client(body \\ nil) do
    module = Module.concat(Sap.TestClients, "Client#{System.unique_integer([:positive])}")

    contents =
      quote do
        use Sap.Client, otp_app: :sap
        unquote(body)
      end

    Module.create(module, contents, Macro.Env.location(__ENV__))
    ExUnit.Callbacks.on_exit(fn -> :persistent_term.erase({Sap.Client, module}) end)
    module
  end

  @doc "Sends `body` as a JSON response."
  def json(conn, status \\ 200, body) do
    conn
    |> Plug.Conn.put_resp_content_type("application/json")
    |> Plug.Conn.send_resp(status, JSON.encode!(body))
  end

  @doc "A SAP OData V2 error body."
  def sap_error(code, message, details \\ []) do
    %{
      "error" => %{
        "code" => code,
        "message" => %{"lang" => "en", "value" => message},
        "innererror" => %{"errordetails" => details}
      }
    }
  end

  @doc "Consumes the message for the client's boot-time CSRF fetch."
  defmacro await_boot do
    quote do
      assert_receive {:sap, %{csrf_fetch?: true}}, 1_000
    end
  end

  @doc "The requests received so far that are not CSRF fetches, oldest first."
  def received_requests(acc \\ []) do
    receive do
      {:sap, %{csrf_fetch?: false} = request} -> received_requests([request | acc])
      {:sap, _csrf_fetch} -> received_requests(acc)
    after
      0 -> Enum.reverse(acc)
    end
  end

  @doc "The CSRF fetches received so far."
  def received_csrf_fetches(acc \\ []) do
    receive do
      {:sap, %{csrf_fetch?: true} = request} -> received_csrf_fetches([request | acc])
    after
      0 -> Enum.reverse(acc)
    end
  end

  defp default_csrf(conn, _request) do
    n = System.unique_integer([:positive, :monotonic])

    conn
    |> Plug.Conn.put_resp_header("x-csrf-token", "token-#{n}")
    |> Plug.Conn.put_resp_header("set-cookie", "SAP_SESSIONID=session-#{n}; path=/; secure")
    |> json(%{"d" => %{"EntitySets" => []}})
  end

  defp read(conn) do
    {:ok, body, conn} = Plug.Conn.read_body(conn)
    headers = Map.new(conn.req_headers)

    request = %{
      method: conn.method,
      path: conn.request_path,
      query: URI.decode_query(conn.query_string),
      query_string: conn.query_string,
      headers: headers,
      body: body,
      json: decode(body),
      csrf_fetch?: String.downcase(headers["x-csrf-token"] || "") == "fetch"
    }

    {conn, request}
  end

  defp decode(""), do: nil

  defp decode(body) do
    case JSON.decode(body) do
      {:ok, decoded} -> decoded
      _ -> nil
    end
  end
end
