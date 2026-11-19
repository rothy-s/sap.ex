defmodule Sap.ErrorTest do
  use ExUnit.Case, async: true

  alias Sap.Error
  alias Sap.Error.Detail

  @generic "Exception raised without specific error"

  test "takes code, message and details from errordetails under innererror" do
    body = %{
      "error" => %{
        "code" => "V1/801",
        "message" => %{"lang" => "en", "value" => @generic},
        "innererror" => %{
          "errordetails" => [
            %{"code" => "V1/801", "message" => @generic, "severity" => "error", "target" => ""},
            %{
              "code" => "V1/320",
              "message" => "Material SKU-9 is not defined",
              "severity" => "error",
              "target" => "Material"
            }
          ]
        }
      }
    }

    error = Error.new(:http, status: 400, body: body)

    assert error.code == "V1/801"
    assert error.message == "Material SKU-9 is not defined"

    assert [%Detail{code: "V1/801"}, %Detail{code: "V1/320", severity: "error", target: "Material"}] =
             error.details
  end

  test "reads errordetails placed directly under error, and a JSON string body" do
    body =
      JSON.encode!(%{"error" => %{"code" => "X/1", "errordetails" => [%{"message" => "Specific"}]}})

    assert %Error{code: "X/1", message: "Specific", details: [%Detail{message: "Specific"}]} =
             Error.new(:http, body: body)
  end

  test "falls back to the top-level message, then to a generic one" do
    assert Error.new(:http, body: %{"error" => %{"message" => %{"value" => "Top"}}}).message ==
             "Top"

    assert Error.new(:http, body: %{"error" => %{"message" => "Plain"}}).message == "Plain"
    assert Error.new(:http, body: %{"error" => %{}}).message == "SAP error"
  end

  test "an explicit message wins over the body" do
    assert Error.new(:decode, message: "mine", body: %{"error" => %{"message" => "theirs"}}).message ==
             "mine"
  end

  test "a body that is not a SAP error is truncated, never carried whole into the message" do
    long = String.duplicate("customer-data ", 500)

    assert String.length(Error.new(:http, body: long).message) == 800
    assert String.length(Error.new(:http, body: %{"rows" => Enum.to_list(1..5_000)}).message) <= 800
    assert Error.new(:http, status: 500).message == nil
  end

  test "each kind without a body explains itself" do
    assert Error.new(:not_started).message =~ "supervision tree"
    assert Error.new(:html_session).message =~ "HTML login"
    assert Error.new(:truncated).message =~ "paginated"
    assert Error.new(:timeout, reason: %Req.TransportError{reason: :timeout}).message =~ "timeout"
  end

  test "Exception.message/1 includes kind, service, status, code and url" do
    error =
      Error.new(:http,
        service: "API_SALES_ORDER_SRV",
        status: 400,
        url: "https://sap.test/x",
        body: %{"error" => %{"code" => "V1/801", "message" => "Bad"}}
      )

    assert Exception.message(error) ==
             "SAP http service=API_SALES_ORDER_SRV status=400 code=V1/801 url=https://sap.test/x Bad"

    assert_raise Error, ~r/SAP not_found/, fn -> raise Error.new(:not_found) end
  end

  test "Detail.from_odata/1 drops anything that is not a map" do
    assert Detail.from_odata("nope") == nil

    assert Error.new(:http, body: %{"error" => %{"errordetails" => ["nope", %{"message" => "ok"}]}}).details ==
             [%Detail{message: "ok"}]
  end
end
