defmodule Sap.Odata.QueryTest do
  use ExUnit.Case, async: true
  doctest Sap.Odata.Query

  alias Sap.Odata.Query

  defp filter(query) do
    {"$filter", value} = List.keyfind(Query.params(query), "$filter", 0)
    value
  end

  describe "filters" do
    test "AND-combines clauses in order" do
      query =
        Query.new()
        |> Query.where("A", :eq, "x")
        |> Query.where("B", :eq, "y")

      assert filter(query) == "A eq 'x' and B eq 'y'"
    end

    test "quotes strings, doubling embedded quotes" do
      assert filter(Query.new(filters: [{"Name", :eq, "O'Brien"}])) == "Name eq 'O''Brien'"
    end

    test "renders numbers and booleans bare" do
      assert filter(Query.new(filters: [{"Qty", :ge, 5}])) == "Qty ge 5"
      assert filter(Query.new(filters: [{"Flag", :eq, true}])) == "Flag eq true"
      assert filter(Query.new(filters: [{"Flag", :eq, false}])) == "Flag eq false"
    end

    test "{:raw, _} passes through unquoted, for Edm.DateTime literals" do
      assert filter(Query.new(filters: [{"D", :ge, {:raw, "datetime'2026-01-01T00:00:00'"}}])) ==
               "D ge datetime'2026-01-01T00:00:00'"
    end

    test ":in expands to a parenthesized OR-group, since V2 has no native in" do
      assert filter(Query.new(filters: [{"T", :in, ["107", "108"]}])) ==
               "(T eq '107' or T eq '108')"
    end

    test ":in with an empty list raises rather than emitting an always-false filter" do
      assert_raise ArgumentError, ~r/non-empty value list/, fn ->
        Query.params(Query.new(filters: [{"A", :in, []}]))
      end
    end

    test "unsupported operators and value types raise" do
      assert_raise ArgumentError, ~r/unsupported OData operator/, fn ->
        Query.params(Query.new(filters: [{"A", :contains, "x"}]))
      end

      assert_raise ArgumentError, ~r/unsupported OData filter value/, fn ->
        Query.params(Query.new(filters: [{"A", :eq, %{}}]))
      end
    end
  end

  describe "where_raw/2" do
    test "appends a pre-formatted expression, parenthesized" do
      query = Query.where_raw(Query.new(), "A eq 'x' or B eq 'y'")
      assert filter(query) == "(A eq 'x' or B eq 'y')"
    end

    test "a nil or blank expression leaves the query untouched" do
      assert Query.where_raw(Query.new(), nil) == Query.new()
      assert Query.where_raw(Query.new(), "   ") == Query.new()
    end

    test "parenthesizing keeps a top-level or from swallowing the surrounding and" do
      query =
        Query.new(filters: [{"Type", :eq, "NB"}])
        |> Query.where_raw("A eq '1' or B eq '2'")

      assert filter(query) == "Type eq 'NB' and (A eq '1' or B eq '2')"
    end
  end

  describe "any_of/3" do
    test "ORs every value against every field in one group" do
      query = Query.any_of(Query.new(), ["A", "B"], ["x", "y"])

      assert filter(query) == "(A eq 'x' or B eq 'x' or A eq 'y' or B eq 'y')"
    end

    test "no values leaves the query untouched" do
      assert Query.any_of(Query.new(), ["A"], []) == Query.new()
      assert Query.any_of(Query.new(), ["A"], nil) == Query.new()
    end
  end

  describe "expand, orderby, top and skip" do
    test "renders all of them, with $format last" do
      params =
        Query.new(
          filters: [{"A", :eq, "x"}],
          select: ["S"],
          expand: ["to_One", "to_Two"],
          order_by: ["A", {"B", :desc}],
          top: 100,
          skip: 200
        )
        |> Query.params()

      assert params == [
               {"$filter", "A eq 'x'"},
               {"$select", "S"},
               {"$expand", "to_One,to_Two"},
               {"$orderby", "A,B desc"},
               {"$top", "100"},
               {"$skip", "200"},
               {"$format", "json"}
             ]
    end

    test "an ascending clause renders the explicit keyword" do
      params = Query.new(order_by: [{"A", :asc}]) |> Query.params()
      assert List.keyfind(params, "$orderby", 0) == {"$orderby", "A asc"}
    end

    test "$skip of zero is still emitted" do
      params = Query.new(skip: 0) |> Query.params()
      assert List.keyfind(params, "$skip", 0) == {"$skip", "0"}
    end

    test "unset paging and expansion params are absent" do
      assert Query.params(Query.new(filters: [{"A", :eq, "x"}])) == [
               {"$filter", "A eq 'x'"},
               {"$format", "json"}
             ]
    end

    test "the builders append rather than replace" do
      query =
        Query.new(expand: ["to_One"])
        |> Query.expand("to_Two")
        |> Query.order_by({"A", :asc})
        |> Query.top(10)
        |> Query.skip(20)

      assert query.expand == ["to_One", "to_Two"]

      assert Query.new() |> Query.select("A") |> Query.select(["B", "C"]) |> Map.get(:select) ==
               ["A", "B", "C"]

      assert query.order_by == [{"A", :asc}]
      assert %Query{top: 10, skip: 20} = query
    end

    test "nil clears paging, and negatives are rejected" do
      assert %Query{top: nil} = Query.top(Query.new(top: 5), nil)
      assert_raise FunctionClauseError, fn -> Query.top(Query.new(), -1) end
    end

    test "an unsupported orderby clause raises" do
      assert_raise ArgumentError, ~r/unsupported OData \$orderby clause/, fn ->
        Query.params(Query.new(order_by: [{"A", :sideways}]))
      end
    end
  end

  describe "query_string/1" do
    test "encodes spaces as %20, which some SAP gateways require" do
      qs = Query.new(filters: [{"A", :eq, "x y"}]) |> Query.query_string()

      assert qs =~ "%20"
      refute qs =~ "+"
    end

    test "format: nil omits $format entirely, for $metadata and the CSRF fetch" do
      assert Query.new(format: nil) |> Query.params() == []
    end
  end
end
