defmodule IceReporterWeb.ReportLive do
  use IceReporterWeb, :live_view
  alias IceReporter.Reports
  alias IceReporter.RateLimiter

  def mount(_params, _session, socket) do
    # Subscribe to new reports for real-time updates
    Phoenix.PubSub.subscribe(IceReporter.PubSub, "reports")

    # Get client IP and store in socket assigns
    client_ip =
      case get_connect_info(socket, :peer_data) do
        %{address: ip} -> :inet.ntoa(ip) |> to_string()
        _ -> "127.0.0.1"
      end

    reports = Reports.list_active_reports()

    {:ok,
     socket
     |> assign(:reports_empty?, reports == [])
     |> assign(:client_ip, client_ip)
     |> assign(:rate_limit_message, nil)
     |> assign(:show_captcha, false)
     |> stream(:reports, reports)}
  end

  def handle_event("map_report", params, socket) do
    IO.puts("🗺️ MAP REPORT EVENT RECEIVED!")
    IO.inspect(params, label: "Map report params")

    lat = params["latitude"]
    lng = params["longitude"]
    type = params["type"]

    IO.puts("📍 Creating report with coords: #{lat}, #{lng}, type: #{type}")

    # Check rate limit
    case RateLimiter.check_rate_limit(socket.assigns.client_ip) do
      {:ok, _remaining} ->
        # Rate limit OK, proceed with report creation
        create_report_directly(socket, lat, lng, type)

      {:rate_limited, reset_time} ->
        # Rate limit exceeded, show captcha
        reset_minutes = div(reset_time, 60)

        message =
          "Rate limit reached. Please wait #{reset_minutes} minutes or complete the captcha below."

        {:noreply,
         socket
         |> assign(:rate_limit_message, message)
         |> assign(:show_captcha, true)}
    end
  end

  def handle_event("search_address", %{"value" => query}, socket) do
    # TODO: Implement address search autocomplete
    IO.puts("🔍 Address search: #{query}")
    {:noreply, socket}
  end

  def handle_event("captcha_verified", %{"token" => token}, socket) do
    # TODO: Verify hCaptcha token server-side
    IO.puts("🔐 Captcha verified with token: #{token}")

    # For now, assume verification passed and clear captcha/rate limit
    {:noreply,
     socket
     |> assign(:show_captcha, false)
     |> assign(:rate_limit_message, nil)}
  end

  def handle_event("cancel_captcha", _params, socket) do
    {:noreply,
     socket
     |> assign(:show_captcha, false)
     |> assign(:rate_limit_message, nil)}
  end

  def handle_info({:new_report, report}, socket) do
    IO.puts("📡 PubSub: New report received")

    {:noreply,
     socket
     |> assign(:reports_empty?, false)
     |> stream(:reports, [report])}
  end

  defp create_report_directly(socket, lat, lng, type) do
    # Get address from coordinates
    address = get_address_from_coords(lat, lng)
    IO.puts("🏠 Address: #{address}")

    # Create the report
    case Reports.create_report(%{
           type: type,
           description: "Reported via map click",
           latitude: lat,
           longitude: lng,
           location_description: address
         }) do
      {:ok, report} ->
        IO.puts("✅ Report created successfully: #{report.id}")

        # Increment rate limit counter
        RateLimiter.increment_count(socket.assigns.client_ip)

        # Broadcast to all connected clients
        Phoenix.PubSub.broadcast(IceReporter.PubSub, "reports", {:new_report, report})

        {:noreply, socket}

      {:error, changeset} ->
        IO.puts("❌ Failed to create report:")
        IO.inspect(changeset.errors)
        {:noreply, socket}
    end
  end

  defp get_address_from_coords(lat, lng) do
    url = "https://nominatim.openstreetmap.org/reverse"

    params = [
      format: "json",
      lat: lat,
      lon: lng,
      zoom: 18,
      addressdetails: 1
    ]

    case Req.get(url, params: params) do
      {:ok, %{status: 200, body: %{"display_name" => address}}} ->
        address

      _error ->
        "Location coordinates: #{lat}, #{lng}"
    end
  end

  # Helper functions for template
  def report_type_display("checkpoint"), do: "Checkpoint"
  def report_type_display("facility"), do: "Facility"
  def report_type_display("patrol"), do: "Patrol"
  def report_type_display("vehicle"), do: "Vehicle"
  def report_type_display(_), do: "Unknown"

  def format_time_ago(datetime) do
    now = DateTime.utc_now()
    diff_seconds = DateTime.diff(now, datetime, :second)

    cond do
      diff_seconds < 60 ->
        "#{diff_seconds} seconds ago"

      diff_seconds < 3600 ->
        minutes = div(diff_seconds, 60)
        "#{minutes} minute#{if minutes == 1, do: "", else: "s"} ago"

      diff_seconds < 86400 ->
        hours = div(diff_seconds, 3600)
        "#{hours} hour#{if hours == 1, do: "", else: "s"} ago"

      true ->
        days = div(diff_seconds, 86400)
        "#{days} day#{if days == 1, do: "", else: "s"} ago"
    end
  end
end
