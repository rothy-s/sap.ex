import Config

# The library has no configuration of its own. Each host application configures its own client
# modules (`use Sap.Client, otp_app: :my_app`) under its own OTP app.
#
# This file exists only so the integration tests can load sandbox credentials.
if config_env() == :test and File.exists?(Path.join(__DIR__, "test.override.exs")) do
  import_config "test.override.exs"
end
