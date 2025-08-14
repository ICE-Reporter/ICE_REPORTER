defmodule IceReporterWeb.ReportLive do
  use IceReporterWeb, :live_view
  import Ecto.Query

  alias IceReporter.RateLimiter
  alias IceReporter.Reports
  alias IceReporter.Services.{AddressService, ReportService}

  alias __MODULE__.Helpers

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
     |> assign(:current_language, "en")
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
    # Fallback to IP if no fingerprint, but log when this happens for monitoring
    fingerprint = params["fingerprint"] || socket.assigns.client_ip

    if params["fingerprint"] == nil do
      require Logger
      Logger.warning("Report submitted without browser fingerprint, using fallback identifier")
    end

    # Use ReportService for business logic
    case ReportService.create_report_with_validation(
           %{latitude: lat, longitude: lng, type: type},
           fingerprint,
           socket.assigns.current_language
         ) do
      {:ok, report} ->
        # Report created successfully
        updated_socket =
          socket
          |> assign(:reports_empty?, false)
          |> stream(:reports, [report], at: 0)

        {:noreply, updated_socket}

      {:rate_limited, reset_time} ->
        # Handle rate limiting with captcha
        reset_minutes = ceil((reset_time - System.system_time(:second)) / 60)

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
         |> assign(:pending_report, pending_report)
         |> push_event("captcha_shown", %{})}

      {:error, reason} ->
        {:noreply,
         socket
         |> put_flash(:error, reason)}
    end
  end

  def handle_event("search_address", %{"value" => query}, socket) do
    if String.length(query) >= 3 do
      case AddressService.search_addresses(query) do
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
    case Helpers.verify_hcaptcha_token(token) do
      {:ok, :verified} ->
        handle_successful_captcha(socket)

      {:error, _reason} ->
        handle_failed_captcha(socket)
    end
  end

  def handle_event("cancel_captcha", _params, socket) do
    fingerprint = socket.assigns.current_fingerprint || socket.assigns.client_ip
    removed_report_ids = RateLimiter.cleanup_reports_for_fingerprint(fingerprint)

    updated_socket = cleanup_reports_from_database(socket, removed_report_ids, fingerprint)

    {:noreply,
     updated_socket
     |> assign(:show_captcha, false)
     |> assign(:rate_limit_message, nil)
     |> assign(:pending_report, nil)
     |> push_event("cleanup_temporary_markers", %{fingerprint: fingerprint})
     |> push_event("cleanup_all_markers_for_fingerprint", %{
       fingerprint: fingerprint,
       report_ids: removed_report_ids
     })
     |> push_event("captcha_hidden", %{})
     |> push_event("refresh_browser", %{reason: "captcha_cancelled"})}
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

  def handle_event("validate_coordinates", %{"latitude" => lat, "longitude" => lng}, socket) do
    # Use the same validation logic as report creation
    is_valid = 
      case ReportService.validate_coordinates(lat, lng) do
        :ok -> true
        {:error, _reason} -> false
      end

    {:noreply, push_event(socket, "coordinate_validation_result", %{valid: is_valid})}
  end

  def handle_event("get_us_boundaries", _params, socket) do
    require Logger
    Logger.info("🗺️ Boundaries requested - fetching from database")
    
    # Get all US boundaries from database for map display
    boundaries = IceReporter.Repo.all(IceReporter.Boundary)
    Logger.info("🗺️ Found #{length(boundaries)} boundaries in database")
    
    # Send boundary data to client (limit data size for performance)
    boundary_data = Enum.map(boundaries, fn boundary ->
      %{
        id: boundary.id,
        geometry_type: boundary.geometry_type,
        coordinates: boundary.coordinates,
        name: boundary.name
      }
    end)
    
    Logger.info("🗺️ Sending #{length(boundary_data)} boundaries to client")
    {:noreply, push_event(socket, "us_boundaries_data", %{boundaries: boundary_data})}
  end

  def handle_event("toggle_language", %{"language" => language}, socket) do
    # Force a complete re-render by updating all assigns
    page = socket.assigns.current_page
    per_page = socket.assigns.per_page
    pagination_data = Reports.list_active_reports_paginated(page, per_page)

    {:noreply,
     socket
     |> assign(:current_language, language)
     |> assign(:reports_empty?, pagination_data.reports == [])
     |> assign(:total_pages, pagination_data.total_pages)
     |> assign(:total_count, pagination_data.total_count)
     |> assign(:has_previous, pagination_data.has_previous)
     |> assign(:has_next, pagination_data.has_next)
     |> stream(:reports, pagination_data.reports, reset: true)
     |> push_event("language_changed", %{language: language})
     |> put_flash(
       :info,
       if(language == "es", do: "Idioma cambiado a Español", else: "Language changed to English")
     )}
  end

  def handle_info({:new_report, report}, socket) do
    # Send event to add marker to map
    socket =
      push_event(socket, "add_report_marker", %{
        id: report.id,
        latitude: report.latitude,
        longitude: report.longitude,
        type: report.type
      })
      |> push_event("new_report_added", %{
        type: report_type_display_translated(report.type, socket.assigns.current_language),
        location: report.location_description || "Unknown location"
      })

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
    # Also update the map marker in case location description changed
    {:noreply,
     socket
     |> stream(:reports, [report])
     |> push_event("add_report_marker", %{
       id: report.id,
       latitude: report.latitude,
       longitude: report.longitude,
       type: report.type
     })}
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
    pagination_data = Helpers.load_page_data(page, per_page)

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
    refresh_data = Helpers.refresh_pagination_data(current_page, per_page)

    socket
    |> assign(:total_pages, refresh_data.total_pages)
    |> assign(:total_count, refresh_data.total_count)
    |> assign(:has_previous, refresh_data.has_previous)
    |> assign(:has_next, refresh_data.has_next)
  end

  # Delegate helper functions to the Helpers module
  defdelegate format_time_ago(datetime), to: Helpers
  defdelegate report_type_display(type), to: Helpers
  defdelegate report_type_display_translated(type, language), to: Helpers

  # Extracted helper functions for captcha handling

  defp handle_successful_captcha(socket) do
    fingerprint = socket.assigns.current_fingerprint || socket.assigns.client_ip

    # Reset rate limit for this client's fingerprint
    RateLimiter.reset_rate_limit(fingerprint)

    # Clear report tracking since captcha was successful
    RateLimiter.clear_report_tracking(fingerprint)

    # Create the pending report if one exists
    socket = handle_pending_report(socket)

    {:noreply,
     socket
     |> assign(:show_captcha, false)
     |> assign(:rate_limit_message, nil)
     |> assign(:pending_report, nil)
     |> push_event("captcha_hidden", %{})}
  end

  defp handle_failed_captcha(socket) do
    fingerprint = socket.assigns.current_fingerprint || socket.assigns.client_ip
    removed_report_ids = RateLimiter.cleanup_reports_for_fingerprint(fingerprint)

    updated_socket = cleanup_reports_from_database(socket, removed_report_ids, fingerprint)

    {:noreply,
     updated_socket
     |> put_flash(
       :error,
       if(socket.assigns.current_language == "es",
         do: "Falló la verificación del captcha. Por favor intente de nuevo.",
         else: "Captcha verification failed. Please try again."
       )
     )
     |> push_event("cleanup_temporary_markers", %{fingerprint: fingerprint})
     |> push_event("cleanup_all_markers_for_fingerprint", %{
       fingerprint: fingerprint,
       report_ids: removed_report_ids
     })}
  end

  defp handle_pending_report(socket) do
    case socket.assigns[:pending_report] do
      %{latitude: lat, longitude: lng, type: type, fingerprint: fp} ->
        # Create the report that was pending captcha verification using ReportService
        case ReportService.create_report_with_validation(
               %{latitude: lat, longitude: lng, type: type},
               fp,
               socket.assigns.current_language
             ) do
          {:ok, report} ->
            socket
            |> assign(:reports_empty?, false)
            |> stream(:reports, [report], at: 0)
            |> put_flash(
              :info,
              if(socket.assigns.current_language == "es",
                do: "¡Verificación exitosa! Su reporte ha sido enviado.",
                else: "Verification successful! Your report has been submitted."
              )
            )

          {:error, reason} ->
            socket
            |> put_flash(
              :error,
              if(socket.assigns.current_language == "es",
                do: "Verificación exitosa pero falló al enviar el reporte: #{reason}",
                else: "Verification successful but failed to submit report: #{reason}"
              )
            )

          {:rate_limited, _reset_time} ->
            # This shouldn't happen after successful captcha, but handle gracefully
            socket
            |> put_flash(
              :error,
              if(socket.assigns.current_language == "es",
                do: "Error inesperado con límite de velocidad.",
                else: "Unexpected rate limit error."
              )
            )
        end

      _ ->
        socket
        |> put_flash(
          :info,
          if(socket.assigns.current_language == "es",
            do: "¡Verificación exitosa! Puede continuar reportando.",
            else: "Verification successful! You can continue reporting."
          )
        )
    end
  end

  defp cleanup_reports_from_database(socket, removed_report_ids, _fingerprint) do
    if removed_report_ids != [] do
      # First, get the actual report structs BEFORE deleting them for proper stream deletion
      reports_to_delete =
        from(r in IceReporter.Report, where: r.id in ^removed_report_ids)
        |> IceReporter.Repo.all()

      # Delete reports from database
      from(r in IceReporter.Report, where: r.id in ^removed_report_ids)
      |> IceReporter.Repo.delete_all()

      # Broadcast removal to all other clients
      Enum.each(removed_report_ids, fn report_id ->
        Phoenix.PubSub.broadcast(
          IceReporter.PubSub,
          "reports",
          {:report_expired, report_id}
        )
      end)

      # Update this user's UI immediately (remove from stream and map)
      Enum.reduce(reports_to_delete, socket, fn report, acc_socket ->
        acc_socket
        |> stream_delete(:reports, report)
        |> push_event("remove_report_marker", %{id: report.id})
      end)
      |> refresh_pagination_info()
    else
      socket
    end
  end
end
