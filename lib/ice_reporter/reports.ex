defmodule IceReporter.Reports do
  @moduledoc """
  The Reports context.
  """

  import Ecto.Query, warn: false
  alias IceReporter.Repo
  alias IceReporter.Report

  @doc """
  Returns the list of active reports that haven't expired.
  """
  def list_active_reports do
    now = DateTime.utc_now()

    from(r in Report,
      where: r.is_active == true and r.expires_at > ^now,
      order_by: [desc: r.inserted_at]
    )
    |> Repo.all()
  end

  @doc """
  Gets a single report.
  """
  def get_report!(id), do: Repo.get!(Report, id)

  @doc """
  Creates a report.
  """
  def create_report(attrs \\ %{}) do
    %Report{}
    |> Report.changeset(attrs)
    |> Repo.insert()
    |> case do
      {:ok, report} ->
        # Broadcast the new report to all connected users
        Phoenix.PubSub.broadcast(IceReporter.PubSub, "reports", {:new_report, report})
        {:ok, report}

      error ->
        error
    end
  end

  @doc """
  Deactivates a report.
  """
  def deactivate_report(%Report{} = report) do
    report
    |> Report.changeset(%{is_active: false})
    |> Repo.update()
  end
end
