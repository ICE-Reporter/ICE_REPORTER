defmodule IceReporterWeb.ReportLive do
  use IceReporterWeb, :live_view

  alias IceReporter.Reports
  alias IceReporter.Report

  @impl true
  def mount(_params, _session, socket) do
    if connected?(socket) do
      Phoenix.PubSub.subscribe(IceReporter.PubSub, "reports")
    end

    reports = Reports.list_active_reports()

    {:ok,
     socket
     |> assign(:reports, reports)
     |> assign(:form, to_form(Report.changeset(%Report{}, %{})))
     |> assign(:selected_location, nil)
     |> assign(:reports_empty?, reports == [])
     |> push_event("load_existing_reports", %{reports: serialize_reports(reports)})}
  end

  @impl true
  def handle_event("validate", %{"report" => report_params}, socket) do
    changeset =
      %Report{}
      |> Report.changeset(report_params)
      |> Map.put(:action, :validate)

    {:noreply, assign(socket, form: to_form(changeset))}
  end

  @impl true
  def handle_event("save", %{"report" => report_params}, socket) do
    case Reports.create_report(report_params) do
      {:ok, report} ->
        # Broadcast the new report to update maps across all users
        Phoenix.PubSub.broadcast(
          IceReporter.PubSub,
          "reports",
          {:new_report_with_marker, report}
        )

        {:noreply,
         socket
         |> assign(:form, to_form(Report.changeset(%Report{}, %{})))
         |> assign(:reports_empty?, false)
         |> put_flash(
           :info,
           "Cool report submitted! Thanks for keeping the community informed! ❄️"
         )
         |> push_patch(to: ~p"/reports")}

      {:error, %Ecto.Changeset{} = changeset} ->
        {:noreply, assign(socket, form: to_form(changeset))}
    end
  end

  @impl true
  def handle_event("set_location", %{"lat" => lat, "lng" => lng}, socket) do
    {:noreply,
     socket
     |> assign(:selected_location, %{lat: lat, lng: lng})
     |> assign(:form, to_form(Report.changeset(%Report{}, %{latitude: lat, longitude: lng})))}
  end

  @impl true
  def handle_event("map_report", %{"latitude" => lat, "longitude" => lng, "type" => type}, socket) do
    report_params = %{
      "latitude" => lat,
      "longitude" => lng,
      "type" => type
    }

    case Reports.create_report(report_params) do
      {:ok, report} ->
        # Broadcast to all users including the marker data
        Phoenix.PubSub.broadcast(
          IceReporter.PubSub,
          "reports",
          {:new_report_with_marker, report}
        )

        {:noreply,
         socket
         |> assign(:reports_empty?, false)
         |> put_flash(
           :info,
           "Cool report submitted! Thanks for keeping the community informed! ❄️"
         )}

      {:error, _changeset} ->
        {:noreply, put_flash(socket, :error, "Oops! Couldn't submit that report. Try again!")}
    end
  end

  @impl true
  def handle_event("deactivate_report", %{"id" => id}, socket) do
    report = Reports.get_report!(id)
    {:ok, _} = Reports.deactivate_report(report)

    # Remove the marker from all maps
    Phoenix.PubSub.broadcast(
      IceReporter.PubSub,
      "reports",
      {:remove_report_marker, report}
    )

    {:noreply,
     socket
     |> put_flash(:info, "Report deactivated")
     |> push_patch(to: ~p"/reports")}
  end

  @impl true
  def handle_info({:new_report, report}, socket) do
    reports = [report | socket.assigns.reports]

    {:noreply,
     socket
     |> assign(:reports, reports)
     |> assign(:reports_empty?, false)}
  end

  @impl true
  def handle_info({:new_report_with_marker, report}, socket) do
    reports = [report | socket.assigns.reports]

    {:noreply,
     socket
     |> assign(:reports, reports)
     |> assign(:reports_empty?, false)
     |> push_event("add_report_marker", %{
       latitude: report.latitude,
       longitude: report.longitude,
       type: report.type,
       id: report.id
     })}
  end

  @impl true
  def handle_info({:remove_report_marker, report}, socket) do
    reports = Enum.reject(socket.assigns.reports, &(&1.id == report.id))

    {:noreply,
     socket
     |> assign(:reports, reports)
     |> assign(:reports_empty?, reports == [])
     |> push_event("remove_report_marker", %{id: report.id})}
  end

  defp serialize_reports(reports) do
    Enum.map(reports, fn report ->
      %{
        id: report.id,
        latitude: report.latitude,
        longitude: report.longitude,
        type: report.type
      }
    end)
  end

  defp format_time_ago(datetime) do
    datetime_utc =
      case datetime do
        %DateTime{} -> datetime
        %NaiveDateTime{} -> DateTime.from_naive!(datetime, "Etc/UTC")
      end

    diff = DateTime.diff(DateTime.utc_now(), datetime_utc, :minute)

    cond do
      diff < 1 -> "Just now"
      diff < 60 -> "#{diff} minutes ago"
      diff < 1440 -> "#{div(diff, 60)} hours ago"
      true -> "#{div(diff, 1440)} days ago"
    end
  end

  defp report_type_display(type) do
    case type do
      "checkpoint" -> "🛑 CHECKPOINT"
      "raid" -> "🏠 OPERATION"
      "patrol" -> "👮 PATROL"
      "detention" -> "🧊 FACILITY"
      _ -> "📍 REPORT"
    end
  end
end
