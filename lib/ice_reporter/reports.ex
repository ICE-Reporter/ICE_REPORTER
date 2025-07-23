defmodule IceReporter.Reports do
  @moduledoc """
  The Reports context module handles all database operations for reports.

  This module provides functions for creating, reading, updating, and managing
  reports in the system. It includes functionality for:

  - Creating new reports with automatic PubSub broadcasting
  - Retrieving active reports with pagination support
  - Updating report addresses asynchronously 
  - Managing report lifecycle (activation/deactivation)

  All functions in this module interact directly with the database through
  Ecto queries and handle PubSub broadcasting for real-time updates.
  """

  import Ecto.Query, warn: false
  alias IceReporter.Repo
  alias IceReporter.Report

  @doc """
  Returns the list of active reports that haven't expired.

  Fetches all reports where `is_active` is true and `expires_at` is in the future,
  ordered by insertion date (newest first).

  ## Returns
    - List of %Report{} structs
  """
  @spec list_active_reports() :: [Report.t()]
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

  Uses a single query with window functions for optimal performance,
  avoiding N+1 queries by fetching both results and total count together.

  ## Parameters
    - page: Page number (1-based), defaults to 1
    - per_page: Number of reports per page, defaults to 10
    
  ## Returns
    - Map containing:
      - :reports - List of %Report{} structs for the current page
      - :page - Current page number
      - :per_page - Reports per page
      - :total_count - Total number of active reports
      - :total_pages - Total number of pages
      - :has_previous - Boolean indicating if previous page exists
      - :has_next - Boolean indicating if next page exists
  """
  @spec list_active_reports_paginated(pos_integer(), pos_integer()) :: %{
          reports: [Report.t()],
          page: pos_integer(),
          per_page: pos_integer(),
          total_count: non_neg_integer(),
          total_pages: non_neg_integer(),
          has_previous: boolean(),
          has_next: boolean()
        }
  def list_active_reports_paginated(page \\ 1, per_page \\ 10) do
    now = DateTime.utc_now()
    offset = (page - 1) * per_page

    # Single query with window function to get count and paginated results
    query =
      from(r in Report,
        where: r.is_active == true and r.expires_at > ^now,
        order_by: [desc: r.inserted_at],
        select: %{
          report: r,
          total_count: count() |> over()
        },
        limit: ^per_page,
        offset: ^offset
      )

    results = Repo.all(query)

    # Extract reports and count from results
    {reports, total_count} =
      case results do
        [] ->
          # No results, get total count separately only when empty
          total_count =
            from(r in Report,
              where: r.is_active == true and r.expires_at > ^now
            )
            |> Repo.aggregate(:count, :id)

          {[], total_count}

        [first | _] = results ->
          reports = Enum.map(results, & &1.report)
          total_count = first.total_count
          {reports, total_count}
      end

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
  Gets a single report by ID.

  Raises Ecto.NoResultsError if no report with the given ID is found.

  ## Parameters
    - id: The report ID
    
  ## Returns
    - %Report{} struct
    
  ## Raises
    - Ecto.NoResultsError if report not found
  """
  @spec get_report!(integer()) :: Report.t()
  def get_report!(id), do: Repo.get!(Report, id)

  @doc """
  Creates a new report with the given attributes.

  Automatically broadcasts the new report to all connected clients via PubSub
  if creation is successful. Logs any database errors for debugging.

  ## Parameters
    - attrs: Map of report attributes (type, description, latitude, longitude, etc.)
    
  ## Returns
    - {:ok, %Report{}} on successful creation
    - {:error, %Ecto.Changeset{}} on validation or database errors
  """
  @spec create_report(map()) :: {:ok, Report.t()} | {:error, Ecto.Changeset.t()}
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
  Updates a report's location description (address).

  This function is typically called asynchronously after the initial report
  creation to populate the address from coordinates via external geocoding APIs.
  Broadcasts the updated report to all connected clients.

  ## Parameters
    - report: %Report{} struct to update
    - address: String containing the resolved address
    
  ## Returns
    - {:ok, %Report{}} on successful update
    - {:error, %Ecto.Changeset{}} on validation or database errors
  """
  @spec update_report_address(Report.t(), String.t()) ::
          {:ok, Report.t()} | {:error, Ecto.Changeset.t()}
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
  Deactivates a report by setting is_active to false.

  Deactivated reports will not appear in active report listings
  but are preserved in the database for historical purposes.

  ## Parameters
    - report: %Report{} struct to deactivate
    
  ## Returns
    - {:ok, %Report{}} on successful deactivation
    - {:error, %Ecto.Changeset{}} on validation or database errors
  """
  @spec deactivate_report(Report.t()) :: {:ok, Report.t()} | {:error, Ecto.Changeset.t()}
  def deactivate_report(%Report{} = report) do
    report
    |> Report.changeset(%{is_active: false})
    |> Repo.update()
  end
end
