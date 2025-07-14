defmodule IceReporterWeb.ReportLive do
  use IceReporterWeb, :live_view

  alias IceReporter.Reports
  alias IceReporter.Report

  def mount(_params, _session, socket) do
    reports = Reports.list_active_reports()

    {:ok,
     socket
     |> assign(:reports, reports)
     |> assign(:reports_empty?, reports == [])
     |> assign(:address_suggestions, [])
     |> push_event("load_existing_reports", %{reports: format_reports_for_js(reports)})}
  end

  # Simple test event handler for debugging
  # Simple test button event handler for debugging
  def handle_event("test_button", _params, socket) do
    IO.puts("🧪 TEST BUTTON CLICKED! LiveView events are working!")
    {:noreply, socket}
  end

  def handle_event("test_event", params, socket) do
    IO.puts("🧪 TEST EVENT RECEIVED!")
    IO.inspect(params, label: "Test params")
    {:noreply, socket}
  end

  # Map report event handler with extensive debugging
  def handle_event("map_report", params, socket) do
    IO.puts("🗺️ MAP REPORT EVENT RECEIVED!")
    IO.inspect(params, label: "Map report params")

    case create_report_from_params(params) do
      {:ok, report} ->
        IO.puts("✅ Report created successfully: #{report.id}")

        # Broadcast to all connected clients
        Phoenix.PubSub.broadcast(
          IceReporter.PubSub,
          "reports",
          {:new_report, report}
        )

        # Update local state
        updated_reports = [report | socket.assigns.reports]

        {:noreply,
         socket
         |> assign(:reports, updated_reports)
         |> assign(:reports_empty?, false)
         |> push_event("add_report_marker", %{
           id: report.id,
           latitude: report.latitude,
           longitude: report.longitude,
           type: report.type
         })}

      {:error, changeset} ->
        IO.puts("❌ Failed to create report")
        IO.inspect(changeset.errors, label: "Changeset errors")
        {:noreply, socket}
    end
  end

  # Address search event handler with debugging
  def handle_event("search_address", %{"value" => query}, socket) do
    IO.puts("🔍 ADDRESS SEARCH EVENT RECEIVED!")
    IO.inspect(query, label: "Search query")

    if String.length(query) >= 4 do
      IO.puts("📍 Query long enough, searching...")

      case search_addresses(query) do
        {:ok, suggestions} ->
          IO.puts("✅ Found #{length(suggestions)} suggestions")
          {:noreply, assign(socket, :address_suggestions, suggestions)}

        {:error, reason} ->
          IO.puts("❌ Address search failed: #{reason}")
          {:noreply, assign(socket, :address_suggestions, [])}
      end
    else
      IO.puts("📍 Query too short, clearing suggestions")
      {:noreply, assign(socket, :address_suggestions, [])}
    end
  end

  def handle_event(
        "select_address",
        %{"lat" => lat, "lng" => lng, "display_name" => display_name},
        socket
      ) do
    IO.puts("🎯 ADDRESS SELECTED!")
    IO.inspect({lat, lng, display_name}, label: "Selected address")

    {:noreply,
     socket
     |> assign(:address_suggestions, [])
     |> push_event("fly_to_location", %{latitude: lat, longitude: lng})}
  end

  # Clear suggestions when input is cleared
  def handle_event("clear_suggestions", _params, socket) do
    IO.puts("🧹 CLEARING SUGGESTIONS")
    {:noreply, assign(socket, :address_suggestions, [])}
  end

  # Handle PubSub broadcasts
  def handle_info({:new_report, report}, socket) do
    IO.puts("📡 PubSub: New report received")

    updated_reports = [report | socket.assigns.reports]

    {:noreply,
     socket
     |> assign(:reports, updated_reports)
     |> assign(:reports_empty?, false)
     |> push_event("add_report_marker", %{
       id: report.id,
       latitude: report.latitude,
       longitude: report.longitude,
       type: report.type
     })}
  end

  # Private helper functions
  defp create_report_from_params(params) do
    # Extract coordinates and type
    latitude = Map.get(params, "latitude")
    longitude = Map.get(params, "longitude")
    type = Map.get(params, "type")

    IO.puts("📍 Creating report with coords: #{latitude}, #{longitude}, type: #{type}")

    # Reverse geocode to get address
    location_description =
      case reverse_geocode(latitude, longitude) do
        {:ok, address} -> address
        {:error, _} -> "Location: #{latitude}, #{longitude}"
      end

    IO.puts("🏠 Address: #{location_description}")

    # Create report
    Reports.create_report(%{
      type: type,
      latitude: latitude,
      longitude: longitude,
      location_description: location_description,
      description: "Reported via map click"
    })
  end

  defp search_addresses(query) do
    url = "https://nominatim.openstreetmap.org/search"

    params = [
      q: query,
      format: "json",
      limit: 5,
      countrycodes: "us",
      addressdetails: 1
    ]

    case Req.get(url, params: params) do
      {:ok, %{status: 200, body: results}} ->
        suggestions =
          Enum.map(results, fn result ->
            %{
              display_name: result["display_name"],
              lat: String.to_float(result["lat"]),
              lng: String.to_float(result["lon"])
            }
          end)

        {:ok, suggestions}

      {:error, reason} ->
        {:error, reason}
    end
  rescue
    error ->
      IO.puts("🚨 Address search error: #{inspect(error)}")
      {:error, "Search failed"}
  end

  defp reverse_geocode(latitude, longitude) do
    url = "https://nominatim.openstreetmap.org/reverse"

    params = [
      lat: latitude,
      lon: longitude,
      format: "json",
      addressdetails: 1
    ]

    case Req.get(url, params: params) do
      {:ok, %{status: 200, body: result}} ->
        address = result["display_name"] || "Unknown location"
        {:ok, address}

      {:error, reason} ->
        {:error, reason}
    end
  rescue
    _error ->
      {:error, "Reverse geocoding failed"}
  end

  defp format_reports_for_js(reports) do
    Enum.map(reports, fn report ->
      %{
        id: report.id,
        latitude: report.latitude,
        longitude: report.longitude,
        type: report.type
      }
    end)
  end

  defp format_time_ago(naive_datetime) do
    # Convert NaiveDateTime to UTC DateTime for comparison
    datetime = DateTime.from_naive!(naive_datetime, "Etc/UTC")
    now = DateTime.utc_now()
    diff = DateTime.diff(now, datetime, :minute)

    cond do
      diff < 1 -> "Just now"
      diff < 60 -> "#{diff} minutes ago"
      diff < 1440 -> "#{div(diff, 60)} hours ago"
      true -> "#{div(diff, 1440)} days ago"
    end
  end

  defp report_type_display(type) do
    case type do
      "checkpoint" -> "CHECKPOINT"
      "raid" -> "OPERATION"
      "patrol" -> "PATROL"
      "detention" -> "FACILITY"
      _ -> "REPORT"
    end
  end
end
