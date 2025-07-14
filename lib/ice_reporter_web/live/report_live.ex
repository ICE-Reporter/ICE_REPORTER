defmodule IceReporterWeb.ReportLive do
  use IceReporterWeb, :live_view

  alias IceReporter.Reports
  alias IceReporter.Report
  alias IceReporter.RateLimiter

  def mount(_params, _session, socket) do
    reports = Reports.list_active_reports()

    # Subscribe to real-time updates
    Phoenix.PubSub.subscribe(IceReporter.PubSub, "reports")

    {:ok,
     socket
     |> assign(:reports, reports)
     |> assign(:reports_empty?, reports == [])
     |> assign(:address_suggestions, [])
     |> assign(:show_captcha, false)
     |> assign(:captcha_token, nil)
     |> assign(:rate_limit_message, nil)
     |> push_event("load_existing_reports", %{reports: format_reports_for_js(reports)})}
  end

  # Rate limit check event handler
  def handle_event("check_rate_limit", _params, socket) do
    ip_address = get_client_ip(socket)

    case RateLimiter.check_rate_limit(ip_address) do
      {:ok, remaining} ->
        IO.puts("✅ Rate limit OK: #{remaining} reports remaining")

        {:noreply,
         socket
         |> assign(:show_captcha, false)
         |> assign(:rate_limit_message, nil)}

      {:rate_limited, reset_time} ->
        reset_minutes = div(reset_time - System.system_time(:second), 60)

        message =
          "Rate limit reached! Please complete captcha verification. Limit resets in #{reset_minutes} minutes."

        IO.puts("⚠️ Rate limited: #{message}")

        {:noreply,
         socket
         |> assign(:show_captcha, true)
         |> assign(:rate_limit_message, message)}
    end
  end

  # Handle hCaptcha token submission
  def handle_event("captcha_verified", %{"token" => token}, socket) do
    IO.puts("🔐 Captcha token received: #{String.slice(token, 0..20)}...")

    {:noreply,
     socket
     |> assign(:captcha_token, token)
     |> assign(:show_captcha, false)
     |> assign(:rate_limit_message, nil)}
  end

  # Map report event handler with rate limiting and captcha
  def handle_event("map_report", params, socket) do
    IO.puts("🗺️ MAP REPORT EVENT RECEIVED!")
    IO.inspect(params, label: "Map report params")

    ip_address = get_client_ip(socket)

    # Check rate limit first
    case RateLimiter.check_rate_limit(ip_address) do
      {:ok, _remaining} ->
        # Within rate limit, proceed without captcha
        create_and_process_report(params, socket, ip_address, false)

      {:rate_limited, _reset_time} ->
        # Rate limited, require captcha verification
        captcha_token = socket.assigns.captcha_token

        if captcha_token do
          # Verify captcha token
          case verify_hcaptcha(captcha_token) do
            {:ok, _response} ->
              IO.puts("✅ hCaptcha verified successfully")
              create_and_process_report(params, socket, ip_address, true)

            {:error, reason} ->
              IO.puts("❌ hCaptcha verification failed: #{reason}")

              {:noreply,
               socket
               |> assign(:show_captcha, true)
               |> assign(:captcha_token, nil)
               |> assign(:rate_limit_message, "Captcha verification failed. Please try again.")}
          end
        else
          # No captcha token, show captcha
          {:noreply,
           socket
           |> assign(:show_captcha, true)
           |> assign(
             :rate_limit_message,
             "Rate limit reached! Please complete captcha verification."
           )}
        end
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
  defp create_and_process_report(params, socket, ip_address, used_captcha) do
    case create_report_from_params(params) do
      {:ok, report} ->
        IO.puts("✅ Report created successfully: #{report.id}")

        # Record the submission for rate limiting
        RateLimiter.record_submission(ip_address)

        # Broadcast to all connected clients
        Phoenix.PubSub.broadcast(
          IceReporter.PubSub,
          "reports",
          {:new_report, report}
        )

        # Update local state
        updated_reports = [report | socket.assigns.reports]

        success_message =
          if used_captcha do
            "Report submitted successfully with verification!"
          else
            "Report submitted successfully!"
          end

        {:noreply,
         socket
         |> assign(:reports, updated_reports)
         |> assign(:reports_empty?, false)
         |> assign(:captcha_token, nil)
         |> assign(:show_captcha, false)
         |> assign(:rate_limit_message, success_message)
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

  defp verify_hcaptcha(token) do
    # For now, we'll implement a simple mock verification
    # In production, you'd call the hCaptcha API with your secret key

    # Mock successful verification for development
    if String.length(token) > 10 do
      {:ok, %{"success" => true}}
    else
      {:error, "Invalid token"}
    end
  end

  defp get_client_ip(socket) do
    # Extract client IP from the socket
    case get_connect_info(socket, :peer_data) do
      %{address: address} -> :inet.ntoa(address) |> to_string()
      # fallback for development
      _ -> "127.0.0.1"
    end
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
