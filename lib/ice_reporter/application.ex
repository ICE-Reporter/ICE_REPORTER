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
    
    case Supervisor.start_link(children, opts) do
      {:ok, pid} ->
        # Run seeds after application starts if database is empty
        unless skip_migrations?() do
          seed_if_empty()
        end
        {:ok, pid}
      error ->
        error
    end
  end

  # Tell Phoenix to update the endpoint configuration
  # whenever the application is updated.
  @impl true
  def config_change(changed, _new, removed) do
    IceReporterWeb.Endpoint.config_change(changed, removed)
    :ok
  end

  defp skip_migrations? do
    # Allow migrations to run in production by default
    # Skip only if explicitly disabled
    System.get_env("SKIP_MIGRATIONS") == "true"
  end

  defp seed_if_empty do
    # Check if boundary data exists, if not, run seeds
    Task.start(fn ->
      try do
        count = IceReporter.Repo.aggregate(IceReporter.Boundary, :count, :id)
        # Only seed if we have no boundaries or less than 50 (indicating incomplete import)
        if count == 0 or count < 50 do
          require Logger
          Logger.info("🌱 Found #{count} boundaries - running seeds to load full US boundaries...")
          IceReporter.Release.seed()
          Logger.info("🌱 Seeds completed successfully")
        else
          require Logger
          Logger.info("🌱 Database already seeded with #{count} boundaries, skipping seeds")
        end
      rescue
        error ->
          require Logger
          Logger.error("🌱 Error checking/running seeds: #{inspect(error)}")
      end
    end)
  end
end
