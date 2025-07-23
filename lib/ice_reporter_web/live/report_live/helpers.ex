defmodule IceReporterWeb.ReportLive.Helpers do
  @moduledoc """
  Helper functions for ReportLive that don't fit into other modules.

  This module contains utility functions for formatting, validation,
  and other supporting functionality used by the ReportLive module.
  """

  @doc """
  Formats a datetime as a human-readable "time ago" string.
  """
  def format_time_ago(datetime) do
    now = DateTime.utc_now()
    # Convert NaiveDateTime to UTC DateTime if needed
    utc_datetime =
      case datetime do
        %DateTime{} -> datetime
        %NaiveDateTime{} -> DateTime.from_naive!(datetime, "Etc/UTC")
      end

    diff_seconds = DateTime.diff(now, utc_datetime, :second)

    cond do
      diff_seconds < 60 ->
        "#{diff_seconds} seconds ago"

      diff_seconds < 3600 ->
        minutes = div(diff_seconds, 60)
        "#{minutes} minute#{if minutes == 1, do: "", else: "s"} ago"

      diff_seconds < 86_400 ->
        hours = div(diff_seconds, 3600)
        "#{hours} hour#{if hours == 1, do: "", else: "s"} ago"

      true ->
        days = div(diff_seconds, 86_400)
        "#{days} day#{if days == 1, do: "", else: "s"} ago"
    end
  end

  @doc """
  Returns the display name for a report type in English.
  """
  def report_type_display("checkpoint"), do: "Checkpoint"
  def report_type_display("raid"), do: "Operation"
  def report_type_display("patrol"), do: "Patrol"
  def report_type_display("detention"), do: "Facility"
  def report_type_display(_), do: "Unknown"

  @doc """
  Returns the translated display name for a report type.
  """
  def report_type_display_translated(type, "es") do
    case type do
      "checkpoint" -> "Punto de control"
      "raid" -> "Operación"
      "patrol" -> "Patrulla"
      "detention" -> "Instalación"
      _ -> type
    end
  end

  def report_type_display_translated(type, _), do: report_type_display(type)

  @doc """
  Verifies an hCaptcha token with the hCaptcha service.
  """
  def verify_hcaptcha_token(token) do
    secret_key =
      Application.get_env(
        :ice_reporter,
        :hcaptcha_secret,
        "0x0000000000000000000000000000000000000000"
      )

    url = "https://hcaptcha.com/siteverify"

    params = %{
      secret: secret_key,
      response: token
    }

    case Req.post(url,
           form: params,
           headers: [{"User-Agent", "IceReporter/1.0"}],
           receive_timeout: 10_000
         ) do
      {:ok, %{status: 200, body: %{"success" => true}}} ->
        {:ok, :verified}

      {:ok, %{status: 200, body: %{"success" => false, "error-codes" => errors}}} ->
        {:error, "hCaptcha validation failed: #{inspect(errors)}"}

      {:ok, %{status: status}} ->
        {:error, "hCaptcha API returned status #{status}"}

      {:error, reason} ->
        {:error, "hCaptcha API error: #{inspect(reason)}"}
    end
  end

  @doc """
  Loads pagination data for a specific page.
  """
  def load_page_data(page, per_page) do
    IceReporter.Reports.list_active_reports_paginated(page, per_page)
  end

  @doc """
  Refreshes pagination metadata without changing the current page.
  """
  def refresh_pagination_data(current_page, per_page) do
    pagination_data = load_page_data(current_page, per_page)

    %{
      total_pages: pagination_data.total_pages,
      total_count: pagination_data.total_count,
      has_previous: pagination_data.has_previous,
      has_next: pagination_data.has_next
    }
  end
end
