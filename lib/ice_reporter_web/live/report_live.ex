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
     |> assign(:selected_location, nil)
     |> assign(:reports_empty?, reports == [])
     |> assign(:address_search, "")
     |> assign(:address_suggestions, [])
     |> push_event("load_existing_reports", %{reports: serialize_reports(reports)})}
  end

  @impl true
  def handle_event("search_address", %{"value" => query}, socket) when byte_size(query) >= 4 do
    # Use Nominatim (OpenStreetMap) for free geocoding
    suggestions = search_addresses(query)

    {:noreply,
     socket
     |> assign(:address_search, query)
     |> assign(:address_suggestions, suggestions)
     |> push_event("show_address_suggestions", %{suggestions: suggestions})}
  end

  @impl true
  def handle_event("search_address", %{"value" => query}, socket) do
    {:noreply,
     socket
     |> assign(:address_search, query)
     |> assign(:address_suggestions, [])
     |> push_event("hide_address_suggestions", %{})}
  end

  @impl true
  def handle_event("select_address", %{"lat" => lat, "lng" => lng, "address" => address}, socket) do
    {:noreply,
     socket
     |> assign(:address_search, address)
     |> assign(:address_suggestions, [])
     |> push_event("fly_to_address", %{lat: lat, lng: lng, address: address})}
  end

  @impl true
  def handle_event("map_report", %{"latitude" => lat, "longitude" => lng, "type" => type}, socket) do
    IO.puts("🧊 DEBUG: Received map_report event - lat: #{lat}, lng: #{lng}, type: #{type}")
    # Get address from coordinates using reverse geocoding
    address = reverse_geocode(lat, lng)

    report_params = %{
      "latitude" => lat,
      "longitude" => lng,
      "type" => type,
      "location_description" => address
    }

    case Reports.create_report(report_params) do
      {:ok, report} ->
        IO.puts("🧊 DEBUG: Report created successfully with ID: #{report.id}")
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

      {:error, changeset} ->
        IO.puts("🧊 DEBUG: Report creation failed: #{inspect(changeset.errors)}")
        {:noreply, put_flash(socket, :error, "Oops! Couldn't submit that report. Try again!")}
    end
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

  defp search_addresses(query) do
    # Use Nominatim (OpenStreetMap) geocoding service for free address search
    url = "https://nominatim.openstreetmap.org/search"

    params = %{
      q: query,
      format: "json",
      addressdetails: 1,
      limit: 5,
      # Limit to US addresses
      countrycodes: "us"
    }

    case Req.get(url, params: params) do
      {:ok, %{status: 200, body: results}} when is_list(results) ->
        Enum.map(results, fn result ->
          %{
            address: result["display_name"],
            lat: String.to_float(result["lat"]),
            lng: String.to_float(result["lon"])
          }
        end)

      _ ->
        []
    end
  rescue
    _ -> []
  end

  defp reverse_geocode(lat, lng) do
    # Use Nominatim reverse geocoding to get address from coordinates
    url = "https://nominatim.openstreetmap.org/reverse"

    params = %{
      lat: lat,
      lon: lng,
      format: "json",
      addressdetails: 1
    }

    case Req.get(url, params: params) do
      {:ok, %{status: 200, body: result}} when is_map(result) ->
        result["display_name"] || "Unknown Location"

      _ ->
        "#{lat}, #{lng}"
    end
  rescue
    _ -> "#{lat}, #{lng}"
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
