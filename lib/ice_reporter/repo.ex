defmodule IceReporter.Repo do
  use Ecto.Repo,
    otp_app: :ice_reporter,
    adapter: Ecto.Adapters.SQLite3
end
