# Integration tests talk to a real SAP sandbox, and `:integration_write` creates a real sales order.
# Neither runs by default; see test/integration/sandbox_test.exs.
ExUnit.start(exclude: [:integration, :integration_write])
