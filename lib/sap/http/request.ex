defmodule Sap.HTTP.Request do
  @moduledoc """
  One HTTP request, fully built, for a `Sap.HTTP.Adapter` to send.

    * `:method` - `:get`, `:post`, `:patch`, `:put` or `:delete`
    * `:url` - the complete URL, query string included and already encoded. Send it as it is.
    * `:headers` - `{name, value}` pairs, including `Authorization`. Send all of them.
    * `:body` - the encoded body as a binary, or `nil`
    * `:receive_timeout` - milliseconds to wait for the response

  The headers and body are left out of `inspect/1` output: the headers carry credentials and the
  body can carry customer data.
  """

  @type method :: :get | :post | :patch | :put | :delete

  @type t :: %__MODULE__{
          method: method(),
          url: String.t(),
          headers: [{String.t(), String.t()}],
          body: binary() | nil,
          receive_timeout: pos_integer()
        }

  @derive {Inspect, except: [:headers, :body]}
  @enforce_keys [:method, :url, :receive_timeout]
  defstruct [:method, :url, :receive_timeout, headers: [], body: nil]
end
