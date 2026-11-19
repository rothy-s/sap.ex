defmodule Sap.DoctestTest do
  use ExUnit.Case, async: true

  doctest Sap.Client.Config
  doctest Sap.HTTP.Response
  doctest Sap.Operation
  doctest Sap.Odata.Query
  doctest Sap.Odata.Encode
  doctest Sap.Odata.Decode
  doctest Sap.Odata.Date
end
