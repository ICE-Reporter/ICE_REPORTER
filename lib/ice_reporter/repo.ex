defmodule IceReporter.Repo do
  use Ecto.Repo,
    otp_app: :ice_reporter,
    adapter: Ecto.Adapters.Postgres
end
