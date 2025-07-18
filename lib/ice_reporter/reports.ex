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
  Returns a paginated list of active reports that haven't expired.
  """
  def list_active_reports_paginated(page \\ 1, per_page \\ 10) do
    now = DateTime.utc_now()
    offset = (page - 1) * per_page

    reports_query = from(r in Report,
      where: r.is_active == true and r.expires_at > ^now,
      order_by: [desc: r.inserted_at]
    )

    # Get the total count for pagination info
    total_count = Repo.aggregate(reports_query, :count, :id)
    
    # Get the paginated results
    reports = reports_query
    |> limit(^per_page)
    |> offset(^offset)
    |> Repo.all()

    # Calculate pagination metadata
    total_pages = ceil(total_count / per_page)
    has_previous = page > 1
    has_next = page < total_pages

    %{
      reports: reports,
      page: page,
      per_page: per_page,
      total_count: total_count,
      total_pages: total_pages,
      has_previous: has_previous,
      has_next: has_next
    }
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

      {:error, changeset} = error ->
        # Log the error for debugging
        require Logger
        Logger.error("Database error creating report: #{inspect(changeset.errors)}")
        error
    end
  end

  @doc """
  Updates a report's address.
  """
  def update_report_address(%Report{} = report, address) do
    report
    |> Report.changeset(%{location_description: address})
    |> Repo.update()
    |> case do
      {:ok, updated_report} ->
        # Broadcast the updated report
        Phoenix.PubSub.broadcast(IceReporter.PubSub, "reports", {:report_updated, updated_report})
        {:ok, updated_report}

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
