defmodule IceReporter.Application do
  # See https://hexdocs.pm/elixir/Application.html
  # for more information on OTP Applications
  @moduledoc false

  use Application

  @impl true
  def start(_type, _args) do
    children = [
      IceReporterWeb.Telemetry,
      IceReporter.Repo,
      {Ecto.Migrator,
       repos: Application.fetch_env!(:ice_reporter, :ecto_repos), skip: skip_migrations?()},
      {DNSCluster, query: Application.get_env(:ice_reporter, :dns_cluster_query) || :ignore},
      {Phoenix.PubSub, name: IceReporter.PubSub},
      {Task.Supervisor, name: IceReporter.TaskSupervisor},
      IceReporter.RateLimiter,
      IceReporter.CleanupWorker,
      IceReporterWeb.Endpoint
    ]

    # See https://hexdocs.pm/elixir/Supervisor.html
    # for other strategies and supported options
    opts = [strategy: :one_for_one, name: IceReporter.Supervisor]
    Supervisor.start_link(children, opts)
  end

  # Tell Phoenix to update the endpoint configuration
  # whenever the application is updated.
  @impl true
  def config_change(changed, _new, removed) do
    IceReporterWeb.Endpoint.config_change(changed, removed)
    :ok
  end

  defp skip_migrations? do
    # Skip migrations when running in releases (production)
    System.get_env("RELEASE_NAME") != nil
  end
end
