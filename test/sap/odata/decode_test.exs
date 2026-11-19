defmodule Sap.Odata.DecodeTest do
  use ExUnit.Case, async: true

  alias Sap.Odata.Decode

  describe "string/1" do
    test "trims, and reads blank as absent" do
      assert Decode.string("  4600111454 ") == "4600111454"
      assert Decode.string("   ") == nil
      assert Decode.string(nil) == nil
    end

    test "stringifies non-binary values rather than raising" do
      assert Decode.string(42) == "42"
      assert Decode.string(:atom) == "atom"
    end
  end

  describe "first_string/2" do
    test "returns the first non-blank value in key order" do
      row = %{"ProductStandardID" => " ", "InternationalArticleNumberCat" => "0123"}

      assert Decode.first_string(row, ["ProductStandardID", "InternationalArticleNumberCat"]) ==
               "0123"
    end

    test "is nil when every key is blank or missing" do
      assert Decode.first_string(%{"A" => ""}, ["A", "B"]) == nil
    end
  end

  describe "date/1" do
    test "reads SAP's /Date(epoch_ms)/ form, with or without an offset" do
      assert Decode.date("/Date(1767225600000)/") == ~D[2026-01-01]
      assert Decode.date("/Date(1767225600000+0000)/") == ~D[2026-01-01]
    end

    test "reads ISO-8601 dates and datetimes" do
      assert Decode.date("2026-01-01") == ~D[2026-01-01]
      assert Decode.date("2026-01-01T12:30:00") == ~D[2026-01-01]
    end

    test "passes Date and DateTime values through as a Date" do
      assert Decode.date(~D[2026-01-01]) == ~D[2026-01-01]
      assert Decode.date(~U[2026-01-01 12:30:00Z]) == ~D[2026-01-01]
    end

    test "anything unparseable is nil" do
      assert Decode.date(nil) == nil
      assert Decode.date("/Date(garbage)/") == nil
      assert Decode.date("not a date") == nil
      assert Decode.date(1_767_225_600_000) == nil
    end
  end

  describe "boolean/1" do
    test "reads JSON booleans, legacy X flags and their string forms" do
      assert Decode.boolean(true) == true
      assert Decode.boolean(false) == false
      assert Decode.boolean("X") == true
      assert Decode.boolean("") == false
      assert Decode.boolean("true") == true
      assert Decode.boolean("false") == false
      assert Decode.boolean(nil) == nil
    end
  end

  describe "nav/2" do
    test "reads rows from every shape SAP sends an expansion in" do
      assert Decode.nav(%{"to_X" => %{"results" => [%{"a" => 1}, "junk"]}}, "to_X") == [%{"a" => 1}]
      assert Decode.nav(%{"to_X" => [%{"a" => 1}]}, "to_X") == [%{"a" => 1}]
      assert Decode.nav(%{"to_X" => %{"a" => 1}}, "to_X") == [%{"a" => 1}]
    end

    test "a deferred, empty or absent navigation is no rows" do
      assert Decode.nav(%{"to_X" => %{"__deferred" => %{"uri" => "x"}}}, "to_X") == []
      assert Decode.nav(%{"to_X" => %{}}, "to_X") == []
      assert Decode.nav(%{"to_X" => nil}, "to_X") == []
      assert Decode.nav(%{}, "to_X") == []
    end
  end
end
