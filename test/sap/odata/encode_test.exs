defmodule Sap.Odata.EncodeTest do
  use ExUnit.Case, async: true
  doctest Sap.Odata.Encode

  alias Sap.Odata.Decode
  alias Sap.Odata.Encode

  describe "epoch/1" do
    test "renders SAP's epoch-milliseconds literal" do
      assert Encode.epoch(~D[2026-01-01]) == "/Date(1767225600000)/"
    end

    test "nil passes through" do
      assert Encode.epoch(nil) == nil
    end
  end

  test "an epoch literal round-trips through Decode.date/1" do
    for date <- [~D[2026-01-01], ~D[2026-07-15], ~D[2027-12-31]] do
      assert Decode.date(Encode.epoch(date)) == date
    end
  end

  describe "number/1" do
    test "a decimal string goes out exactly as given, trailing zeros and all" do
      # SAP distinguishes "24" from "24.000" on some quantity fields, and the string is what the
      # caller read off SAP in the first place - reformatting it here would be this client
      # reinterpreting a value, which it does not do.
      assert Encode.number("24.000") == "24.000"
      assert Encode.number("0.00001") == "0.00001"
      assert Encode.number("  24  ") == "24"
    end

    test "integers are accepted for convenience" do
      assert Encode.number(24) == "24"
    end

    test "a float is rejected rather than quietly reformatted" do
      # Float.to_string/1 can emit exponent notation, which SAP rejects on quantity and amount
      # fields, and by the time a decimal is a float the precision the string form protects is
      # already gone. Failing here sends the caller back to the string.
      # apply/3 rather than a direct call: `number/1` has no float clause, so `Encode.number(24.5)`
      # is a compile-time type error - the guarantee working as intended, but it stops the test
      # compiling, and the runtime behaviour is still worth pinning.
      # credo:disable-for-next-line Credo.Check.Refactor.Apply
      assert_raise ArgumentError, ~r/got float/, fn -> apply(Encode, :number, [24.5]) end
    end

    test "nil passes through" do
      assert Encode.number(nil) == nil
    end
  end

  describe "escape/1" do
    test "doubles embedded single quotes, without adding surrounding ones" do
      assert Encode.escape("O'Brien") == "O''Brien"
      assert Encode.escape("plain") == "plain"
    end

    test "stringifies non-binaries" do
      assert Encode.escape(4_600_111_454) == "4600111454"
    end
  end

  describe "compact/1" do
    test "drops nil and empty-string values" do
      assert Encode.compact(%{"A" => "x", "B" => nil, "C" => ""}) == %{"A" => "x"}
    end

    test "keeps false and zero, which are meaningful values" do
      assert Encode.compact(%{"A" => false, "B" => 0}) == %{"A" => false, "B" => 0}
    end

    test "an all-blank map compacts to empty" do
      assert Encode.compact(%{"A" => nil, "B" => ""}) == %{}
    end
  end
end
