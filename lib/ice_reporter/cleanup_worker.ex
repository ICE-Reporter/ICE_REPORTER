defmodule IceReporter.CleanupWorker do
  @moduledoc """
  Background worker that periodically cleans up expired reports from the database
  and notifies clients to remove expired markers from the map.
  """
  use GenServer
  alias IceReporter.{Repo, Report}
  import Ecto.Query

  # Run every 30 minutes
  @cleanup_interval :timer.minutes(30)
  # Reports expire after 4 hours
  @expiration_hours 4

  def start_link(opts) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  def init(_opts) do
    require Logger

    Logger.info(
      "CleanupWorker started - will clean up reports older than #{@expiration_hours} hours"
    )

    schedule_cleanup()
    {:ok, %{}}
  end

  def handle_info(:cleanup, state) do
    cleanup_expired_reports()
    schedule_cleanup()
    {:noreply, state}
  end

  defp cleanup_expired_reports do
    now = DateTime.utc_now()
    expiration_threshold = DateTime.add(now, -@expiration_hours * 3600, :second)

    # Find expired reports before deleting them so we can notify clients
    expired_reports =
      from(r in Report,
        where: r.expires_at < ^now or r.inserted_at < ^expiration_threshold,
        select: r.id
      )
      |> Repo.all()

    if expired_reports != [] do
      require Logger
      Logger.info("Found #{length(expired_reports)} expired reports to clean up")

      # Notify all clients to remove expired markers
      Enum.each(expired_reports, fn report_id ->
        Phoenix.PubSub.broadcast(
          IceReporter.PubSub,
          "reports",
          {:report_expired, report_id}
        )
      end)

      # Delete expired reports from database
      {deleted_count, _} =
        from(r in Report,
          where: r.expires_at < ^now or r.inserted_at < ^expiration_threshold
        )
        |> Repo.delete_all()

      Logger.info("Cleaned up #{deleted_count} expired reports from database")

      # Broadcast cleanup event to trigger client-side refresh
      Phoenix.PubSub.broadcast(
        IceReporter.PubSub,
        "reports",
        {:cleanup_completed, %{deleted_count: deleted_count, timestamp: now}}
      )
    else
      require Logger
      Logger.debug("No expired reports to clean up")
    end
  end

  defp schedule_cleanup do
    Process.send_after(self(), :cleanup, @cleanup_interval)
  end
end
