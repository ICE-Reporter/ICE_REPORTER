defmodule IceReporterWeb.ReportLive do
  use IceReporterWeb, :live_view
  import Ecto.Query
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

    # Initialize pagination
    page = 1
    per_page = 10
    pagination_data = Reports.list_active_reports_paginated(page, per_page)

    {:ok,
     socket
     |> assign(:reports_empty?, pagination_data.reports == [])
     |> assign(:client_ip, client_ip)
     |> assign(:rate_limit_message, nil)
     |> assign(:show_captcha, false)
     |> assign(:pending_report, nil)
     |> assign(:current_page, page)
     |> assign(:per_page, per_page)
     |> assign(:total_pages, pagination_data.total_pages)
     |> assign(:total_count, pagination_data.total_count)
     |> assign(:has_previous, pagination_data.has_previous)
     |> assign(:has_next, pagination_data.has_next)
     |> stream(:reports, pagination_data.reports)}
  end

  def handle_event("map_report", params, socket) do
    lat = params["latitude"]
    lng = params["longitude"]
    type = params["type"]
    # Fallback to IP if no fingerprint
    fingerprint = params["fingerprint"] || socket.assigns.client_ip

    # Check rate limit using fingerprint instead of IP
    case RateLimiter.check_rate_limit(fingerprint) do
      {:ok, _remaining} ->
        # Rate limit OK, proceed with report creation
        create_report_directly(socket, lat, lng, type, fingerprint)

      {:rate_limited, reset_time} ->
        # Rate limit exceeded, show captcha and store pending report
        reset_minutes = div(reset_time, 60)

        message =
          "Rate limit reached. Please wait #{reset_minutes} minutes or complete the captcha below."

        # Store the pending report data for after captcha verification
        pending_report = %{
          latitude: lat,
          longitude: lng,
          type: type,
          fingerprint: fingerprint
        }

        {:noreply,
         socket
         |> assign(:rate_limit_message, message)
         |> assign(:show_captcha, true)
         |> assign(:current_fingerprint, fingerprint)
         |> assign(:pending_report, pending_report)}
    end
  end

  def handle_event("search_address", %{"value" => query}, socket) do
    if String.length(query) >= 3 do
      case search_addresses(query) do
        {:ok, suggestions} ->
          {:noreply, push_event(socket, "show_address_suggestions", %{suggestions: suggestions})}

        {:error, _reason} ->
          {:noreply, push_event(socket, "hide_address_suggestions", %{})}
      end
    else
      {:noreply, push_event(socket, "hide_address_suggestions", %{})}
    end
  end

  def handle_event("captcha_verified", %{"token" => token}, socket) do
    case verify_hcaptcha_token(token) do
      {:ok, :verified} ->
        # Reset rate limit for this client's fingerprint
        fingerprint = socket.assigns.current_fingerprint || socket.assigns.client_ip
        RateLimiter.reset_rate_limit(fingerprint)

        # Create the pending report if one exists
        socket =
          case socket.assigns[:pending_report] do
            %{latitude: lat, longitude: lng, type: type, fingerprint: fp} ->
              # Create the report that was pending captcha verification
              case create_report_directly(socket, lat, lng, type, fp) do
                {:noreply, updated_socket} ->
                  updated_socket
                  |> put_flash(:info, "Verification successful! Your report has been submitted.")

                _ ->
                  socket
                  |> put_flash(
                    :error,
                    "Verification successful but failed to submit report. Please try again."
                  )
              end

            _ ->
              socket
              |> put_flash(:info, "Verification successful! You can continue reporting.")
          end

        {:noreply,
         socket
         |> assign(:show_captcha, false)
         |> assign(:rate_limit_message, nil)
         |> assign(:pending_report, nil)}

      {:error, reason} ->
        {:noreply,
         socket
         |> put_flash(:error, "Captcha verification failed. Please try again.")}
    end
  end

  def handle_event("cancel_captcha", _params, socket) do
    {:noreply,
     socket
     |> assign(:show_captcha, false)
     |> assign(:rate_limit_message, nil)
     |> assign(:pending_report, nil)}
  end

  def handle_event("select_address", %{"lat" => lat, "lng" => lng, "address" => address}, socket) do
    {:noreply,
     socket
     |> push_event("fly_to_address", %{lat: lat, lng: lng, address: address})
     |> push_event("hide_address_suggestions", %{})}
  end

  def handle_event("fly_to_report", %{"lat" => lat, "lng" => lng, "address" => address}, socket) do
    {:noreply,
     socket
     |> push_event("fly_to_address", %{lat: lat, lng: lng, address: address})}
  end

  def handle_event("next_page", _params, socket) do
    current_page = socket.assigns.current_page
    total_pages = socket.assigns.total_pages

    if current_page < total_pages do
      {:noreply, load_page(socket, current_page + 1)}
    else
      {:noreply, socket}
    end
  end

  def handle_event("previous_page", _params, socket) do
    current_page = socket.assigns.current_page

    if current_page > 1 do
      {:noreply, load_page(socket, current_page - 1)}
    else
      {:noreply, socket}
    end
  end

  def handle_event("go_to_page", %{"page" => page_str}, socket) do
    case Integer.parse(page_str) do
      {page, ""} when page > 0 and page <= socket.assigns.total_pages ->
        {:noreply, load_page(socket, page)}

      _ ->
        {:noreply, socket}
    end
  end

  def handle_info({:new_report, report}, socket) do
    # For pagination, we need to refresh the current page to maintain accurate counts
    # New reports should appear on page 1, so if we're on page 1, refresh
    if socket.assigns.current_page == 1 do
      {:noreply, load_page(socket, 1)}
    else
      # If we're on other pages, just update the pagination metadata
      {:noreply, refresh_pagination_info(socket)}
    end
  end

  def handle_info({:report_updated, report}, socket) do
    # Update the existing report in place (preserves position)
    {:noreply,
     socket
     |> stream(:reports, [report])}
  end

  def handle_info({:report_expired, report_id}, socket) do
    # Remove expired report from stream and push map marker removal event
    # Then refresh pagination info to maintain accurate counts
    {:noreply,
     socket
     |> stream_delete(:reports, %{id: report_id})
     |> push_event("remove_report_marker", %{id: report_id})
     |> refresh_pagination_info()}
  end

  def handle_info({:cleanup_completed, %{deleted_count: count, timestamp: _timestamp}}, socket) do
    # Refresh the current page to maintain accurate pagination
    {:noreply,
     socket
     |> load_page(socket.assigns.current_page)
     |> push_event("cleanup_completed", %{deleted_count: count})}
  end

  # Helper function to load a specific page of reports
  defp load_page(socket, page) do
    per_page = socket.assigns.per_page
    pagination_data = Reports.list_active_reports_paginated(page, per_page)

    socket
    |> assign(:reports_empty?, pagination_data.reports == [])
    |> assign(:current_page, page)
    |> assign(:total_pages, pagination_data.total_pages)
    |> assign(:total_count, pagination_data.total_count)
    |> assign(:has_previous, pagination_data.has_previous)
    |> assign(:has_next, pagination_data.has_next)
    |> stream(:reports, pagination_data.reports, reset: true)
  end

  # Helper function to refresh pagination info without changing the current page
  defp refresh_pagination_info(socket) do
    per_page = socket.assigns.per_page
    current_page = socket.assigns.current_page
    pagination_data = Reports.list_active_reports_paginated(current_page, per_page)

    socket
    |> assign(:total_pages, pagination_data.total_pages)
    |> assign(:total_count, pagination_data.total_count)
    |> assign(:has_previous, pagination_data.has_previous)
    |> assign(:has_next, pagination_data.has_next)
  end

  defp create_report_directly(socket, lat, lng, type, fingerprint) do
    # Convert coordinates to floats if they're strings
    latitude =
      case lat do
        lat when is_binary(lat) -> String.to_float(lat)
        lat when is_number(lat) -> lat / 1.0
        _ -> lat
      end

    longitude =
      case lng do
        lng when is_binary(lng) -> String.to_float(lng)
        lng when is_number(lng) -> lng / 1.0
        _ -> lng
      end

    # Basic geographic validation
    case validate_coordinates(latitude, longitude) do
      :ok ->
        # Coordinates are valid, proceed
        create_validated_report(socket, latitude, longitude, type, fingerprint)

      {:error, reason} ->
        {:noreply,
         socket
         |> put_flash(:error, "Invalid location: #{reason}")}
    end
  end

  defp create_validated_report(socket, latitude, longitude, type, fingerprint) do
    # Create the report first with basic info, then update with address async
    case Reports.create_report(%{
           type: type,
           description: "Reported via map click",
           latitude: latitude,
           longitude: longitude,
           location_description: "Loading address..."
         }) do
      {:ok, report} ->
        # Increment rate limit counter using fingerprint
        identifier = fingerprint || socket.assigns.client_ip
        RateLimiter.increment_count(identifier)

        # Immediately update the UI for the creator (since PubSub might be delayed)
        updated_socket =
          socket
          |> assign(:reports_empty?, false)
          |> stream(:reports, [report], at: 0)

        # Get address asynchronously to avoid blocking
        Task.start(fn ->
          address = get_address_from_coords(latitude, longitude)

          # Update the report with the real address
          Reports.update_report_address(report, address)
        end)

        {:noreply, updated_socket}

      {:error, changeset} ->
        # Show error message to user
        {:noreply,
         socket
         |> put_flash(:error, "Failed to create report. Please try again.")}
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

    case Req.get(url,
           params: params,
           headers: [{"User-Agent", "IceReporter/1.0"}],
           receive_timeout: 15000,
           retry: :transient,
           max_retries: 2
         ) do
      {:ok, %{status: 200, body: result}} ->
        # Use the same formatting logic as the search dropdown
        format_address(result)

      {:ok, %{status: status, body: body}} ->
        "Location coordinates: #{lat}, #{lng}"

      {:error, reason} ->
        "Location coordinates: #{lat}, #{lng}"
    end
  end

  defp search_addresses(query) do
    url = "https://nominatim.openstreetmap.org/search"

    params = [
      format: "json",
      q: query,
      # Increased limit to get more results for landmarks
      limit: 8,
      countrycodes: "us",
      addressdetails: 1,
      # Include various feature types to capture landmarks
      featuretype: "settlement,highway,natural,leisure,amenity,tourism,building"
    ]

    case Req.get(url,
           params: params,
           headers: [{"User-Agent", "IceReporter/1.0"}],
           receive_timeout: 15000,
           retry: :transient,
           max_retries: 2
         ) do
      {:ok, %{status: 200, body: results}} when is_list(results) ->
        suggestions =
          results
          |> Enum.map(fn result ->
            %{
              lat: String.to_float(result["lat"]),
              lng: String.to_float(result["lon"]),
              address: format_address(result)
            }
          end)
          |> Enum.filter(fn suggestion ->
            # Filter out results that are just coordinates or "Unknown Location"
            suggestion.address != "Unknown Location" &&
              !String.contains?(suggestion.address, "Location coordinates:")
          end)
          # Take top 5 after filtering
          |> Enum.take(5)

        {:ok, suggestions}

      {:ok, %{status: status, body: body}} ->
        {:error, "Failed to search addresses"}

      {:error, reason} ->
        {:error, "Failed to search addresses"}
    end
  end

  defp format_address(result) do
    address = result["address"] || %{}

    # Check for landmarks, infrastructure, or non-addressable areas first
    landmark_or_area = detect_landmark_or_area(result, address)

    if landmark_or_area do
      landmark_or_area
    else
      # Build formatted address: "Number Street, City, State ZIP, Country"
      parts = []

      # House number and street
      street_parts =
        [address["house_number"], address["road"]]
        |> Enum.filter(& &1)

      parts = if street_parts != [], do: [Enum.join(street_parts, " ") | parts], else: parts

      # City (try different possible keys)
      city = address["city"] || address["town"] || address["village"] || address["hamlet"]
      parts = if city, do: [city | parts], else: parts

      # State and ZIP
      state_parts =
        [address["state"], address["postcode"]]
        |> Enum.filter(& &1)

      parts = if state_parts != [], do: [Enum.join(state_parts, " ") | parts], else: parts

      # Country
      parts = if address["country"], do: [address["country"] | parts], else: parts

      # Reverse the parts and join with commas, fallback to display_name if parsing fails
      if parts == [] do
        # Try to extract meaningful location from display_name
        format_display_name_fallback(result["display_name"]) || "Unknown Location"
      else
        parts |> Enum.reverse() |> Enum.join(", ")
      end
    end
  end

  defp detect_landmark_or_area(result, address) do
    # Check for various landmark and infrastructure types
    cond do
      # Bridges
      address["bridge"] ->
        "#{address["bridge"]}, #{address["city"] || address["county"]}, #{address["state"]}"

      # Roads, highways, freeways
      address["highway"] && !address["house_number"] ->
        "#{address["highway"]}, #{address["city"] || address["county"]}, #{address["state"]}"

      # Parks, recreation areas
      address["leisure"] ->
        "#{address["leisure"]}, #{address["city"] || address["county"]}, #{address["state"]}"

      # Buildings, monuments, landmarks
      address["building"] && address["name"] ->
        "#{address["name"]}, #{address["city"] || address["county"]}, #{address["state"]}"

      # Amenities (airports, hospitals, etc.)
      address["amenity"] && address["name"] ->
        "#{address["name"]}, #{address["city"] || address["county"]}, #{address["state"]}"

      # Tourist attractions
      address["tourism"] && address["name"] ->
        "#{address["name"]}, #{address["city"] || address["county"]}, #{address["state"]}"

      # Water features
      address["natural"] ->
        "#{address["natural"]}, #{address["city"] || address["county"]}, #{address["state"]}"

      # Check display_name for common landmarks
      result["display_name"] &&
          String.contains?(String.downcase(result["display_name"]), [
            "bridge",
            "highway",
            "freeway",
            "park",
            "airport",
            "hospital",
            "mall",
            "center",
            "plaza"
          ]) ->
        format_display_name_fallback(result["display_name"])

      true ->
        nil
    end
  end

  defp format_display_name_fallback(display_name) when is_binary(display_name) do
    # Extract meaningful parts from display_name for non-addressable areas
    parts = String.split(display_name, ", ")

    case parts do
      # If we have multiple parts, try to construct a meaningful location
      [first | rest] when length(rest) >= 2 ->
        # Take the first part (landmark) and last 2 parts (likely city, state)
        meaningful_parts = [first | Enum.take(rest, -2)]
        Enum.join(meaningful_parts, ", ")

      # If we only have a few parts, use them all
      parts when length(parts) <= 3 ->
        Enum.join(parts, ", ")

      # Otherwise, use the first part and try to find city/state
      [first | rest] ->
        # Look for state patterns in the remaining parts
        state_part =
          Enum.find(rest, fn part ->
            String.length(part) == 2 && String.match?(part, ~r/^[A-Z]{2}$/)
          end)

        if state_part do
          "#{first}, #{state_part}"
        else
          first
        end

      _ ->
        display_name
    end
  end

  defp format_display_name_fallback(_), do: nil

  # Helper functions for template
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

      diff_seconds < 86400 ->
        hours = div(diff_seconds, 3600)
        "#{hours} hour#{if hours == 1, do: "", else: "s"} ago"

      true ->
        days = div(diff_seconds, 86400)
        "#{days} day#{if days == 1, do: "", else: "s"} ago"
    end
  end

  defp validate_coordinates(lat, lng) do
    cond do
      # Basic coordinate range validation
      lat < -90 or lat > 90 ->
        {:error, "Latitude out of range"}

      lng < -180 or lng > 180 ->
        {:error, "Longitude out of range"}

      # Check if coordinates are in obviously invalid locations
      is_in_ocean?(lat, lng) ->
        {:error, "Location appears to be in the ocean"}

      # Check if coordinates are in US (since this is US-focused app)
      not is_in_continental_us?(lat, lng) ->
        {:error, "Location must be within the continental United States"}

      # Check for exact duplicates (suspicious)
      has_exact_duplicate?(lat, lng) ->
        {:error, "Exact location already reported recently"}

      true ->
        :ok
    end
  end

  defp is_in_ocean?(lat, lng) do
    # More precise ocean check to avoid false positives for coastal landmarks
    cond do
      # Deep Atlantic Ocean (well offshore)
      lat > 25 and lat < 45 and lng > -70 and lng < -30 -> true
      # Deep Pacific Ocean (well offshore from West Coast)
      # Only flag areas that are clearly far from shore
      lat > 30 and lat < 50 and lng > -180 and lng < -140 -> true
      # Deep Gulf of Mexico (avoiding coastal areas)
      lat > 24 and lat < 28 and lng > -94 and lng < -85 -> true
      # Caribbean Sea (deep water)
      lat > 15 and lat < 25 and lng > -85 and lng < -60 -> true
      # Default: assume land/coastal area (better false negatives than false positives)
      # This allows bridges, piers, coastal highways, etc.
      true -> false
    end
  end

  defp is_in_continental_us?(lat, lng) do
    # Continental US rough boundaries (excluding Alaska and Hawaii for simplicity)
    lat >= 24.396308 and lat <= 49.384358 and lng >= -125.0 and lng <= -66.93457
  end

  defp has_exact_duplicate?(lat, lng) do
    # Check for reports at exact same coordinates in last hour
    one_hour_ago = DateTime.utc_now() |> DateTime.add(-3600, :second)

    from(r in IceReporter.Report,
      where: r.latitude == ^lat and r.longitude == ^lng and r.inserted_at > ^one_hour_ago,
      limit: 1
    )
    |> IceReporter.Repo.exists?()
  end

  defp verify_hcaptcha_token(token) do
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
           receive_timeout: 10000
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

  def report_type_display("checkpoint"), do: "Checkpoint"
  def report_type_display("raid"), do: "Operation"
  def report_type_display("patrol"), do: "Patrol"
  def report_type_display("detention"), do: "Facility"
  def report_type_display(_), do: "Unknown"
end
