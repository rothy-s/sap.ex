defmodule Sap.HTTP.Response do
  @moduledoc """
  One HTTP response, as a `Sap.HTTP.Adapter` returns it.

    * `:status` - the HTTP status code
    * `:headers` - `{name, value}` pairs. A header sent several times (`set-cookie`) appears
      several times. Names may be in any case.
    * `:body` - the body as a binary. A JSON body may instead be given already decoded, as a map
      or list.
  """

  @type t :: %__MODULE__{
          status: non_neg_integer(),
          headers: [{String.t(), String.t()}],
          body: binary() | map() | list() | nil
        }

  @enforce_keys [:status]
  defstruct [:status, headers: [], body: nil]

  @doc """
  Every value of the header `name`, in order. Names compare case-insensitively.

      iex> response = %Sap.HTTP.Response{status: 200, headers: [{"Set-Cookie", "a=1"}, {"set-cookie", "b=2"}]}
      iex> Sap.HTTP.Response.header(response, "set-cookie")
      ["a=1", "b=2"]
      iex> Sap.HTTP.Response.header(response, "x-csrf-token")
      []
  """
  @spec header(t(), String.t()) :: [String.t()]
  def header(%__MODULE__{headers: headers}, name) when is_binary(name) do
    wanted = String.downcase(name)
    for {key, value} <- headers, String.downcase(key) == wanted, do: value
  end
end
