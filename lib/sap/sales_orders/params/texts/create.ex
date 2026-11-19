defmodule Sap.SalesOrders.Params.Texts.Create do
  @moduledoc """
  A long text of a sales order or item being created (under `to_Text`).

  `:long_text_id` is SAP's text ID (which text this is, for example a header note) and
  `:language` its language key, for example `"EN"`.
  """

  alias Sap.Odata.Encode

  @type t :: %__MODULE__{language: String.t(), long_text_id: String.t(), long_text: String.t()}

  @enforce_keys [:language, :long_text_id, :long_text]
  defstruct [:language, :long_text_id, :long_text]

  @doc "The text body for a deep insert."
  @spec to_odata(t()) :: map()
  def to_odata(%__MODULE__{} = text) do
    Encode.compact(%{
      "Language" => text.language,
      "LongTextID" => text.long_text_id,
      "LongText" => text.long_text
    })
  end
end
