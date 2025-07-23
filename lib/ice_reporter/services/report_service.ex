defmodule IceReporter.Services.ReportService do
  @moduledoc """
  Service for handling report creation and validation logic.

  This module encapsulates the business logic for creating reports,
  including coordinate validation, rate limiting checks, and 
  asynchronous address resolution.
  """

  alias IceReporter.{RateLimiter, Reports}
  alias IceReporter.Services.AddressService
  require Logger

  @type coordinate :: float()
  @type report_type :: String.t()
  @type fingerprint :: String.t()
  @type language :: String.t()

  @doc """
  Creates a new report with the given parameters.

  Handles coordinate validation, rate limiting, and asynchronous
  address resolution.

  ## Parameters
    - params: Map containing report creation parameters
    - fingerprint: Browser fingerprint for rate limiting
    - language: User's current language for localized messages
    
  ## Returns
    - {:ok, report} on success
    - {:error, reason} on failure
  """
  @spec create_report_with_validation(map(), fingerprint(), language()) ::
          {:ok, map()} | {:error, String.t()} | {:rate_limited, integer()}
  def create_report_with_validation(params, fingerprint, language \\ "en") do
    with {:ok, coords} <- validate_and_normalize_coordinates(params),
         :ok <- validate_coordinates(coords.latitude, coords.longitude) do
      case check_rate_limit(fingerprint) do
        {:ok, _remaining} -> create_report(params, coords, fingerprint, language)
        {:rate_limited, reset_time} -> {:rate_limited, reset_time}
      end
    end
  end

  # Private function to handle the actual report creation
  defp create_report(params, coords, fingerprint, language) do
    create_params = %{
      type: params.type,
      description: localized_description(language),
      latitude: coords.latitude,
      longitude: coords.longitude,
      location_description: localized_loading_message(language)
    }

    case Reports.create_report(create_params) do
      {:ok, report} ->
        # Track for rate limiting and potential cleanup
        identifier = fingerprint
        RateLimiter.track_report(identifier, report.id)

        # Start async address resolution
        start_address_resolution(report, coords.latitude, coords.longitude)

        {:ok, report}

      {:error, changeset} ->
        Logger.error("Database error creating report: #{inspect(changeset.errors)}")
        {:error, "Failed to create report. Please try again."}
    end
  end

  @doc """
  Validates and normalizes coordinate input.

  Handles both string and numeric inputs, converting to float.
  """
  @spec validate_and_normalize_coordinates(map()) ::
          {:ok, %{latitude: coordinate(), longitude: coordinate()}} | {:error, String.t()}
  def validate_and_normalize_coordinates(%{latitude: lat, longitude: lng}) do
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

    {:ok, %{latitude: latitude, longitude: longitude}}
  rescue
    _ -> {:error, "Invalid coordinate format"}
  end

  def validate_and_normalize_coordinates(_), do: {:error, "Missing coordinates"}

  @doc """
  Validates that coordinates are within acceptable geographic bounds.

  Currently validates for Continental United States.
  """
  @spec validate_coordinates(coordinate(), coordinate()) :: :ok | {:error, String.t()}
  def validate_coordinates(lat, lng) when is_number(lat) and is_number(lng) do
    # Continental US bounds (approximate)
    if lat >= 20.0 and lat <= 50.0 and lng >= -130.0 and lng <= -60.0 do
      :ok
    else
      {:error, "Coordinates must be within the Continental United States"}
    end
  end

  def validate_coordinates(_, _), do: {:error, "Invalid coordinate values"}

  @doc """
  Checks rate limit for the given fingerprint.
  """
  @spec check_rate_limit(fingerprint()) :: {:ok, integer()} | {:rate_limited, integer()}
  def check_rate_limit(fingerprint) do
    RateLimiter.check_and_increment(fingerprint)
  end

  # Private helper functions

  defp localized_description("es"), do: "Reportado mediante clic en el mapa"
  defp localized_description(_), do: "Reported via map click"

  defp localized_loading_message("es"), do: "Cargando dirección..."
  defp localized_loading_message(_), do: "Loading address..."

  defp start_address_resolution(report, latitude, longitude) do
    Task.Supervisor.start_child(IceReporter.TaskSupervisor, fn ->
      try do
        address = AddressService.get_address_from_coords(latitude, longitude)
        Reports.update_report_address(report, address)
      rescue
        error ->
          Logger.error("Failed to fetch address for report #{report.id}: #{inspect(error)}")
          # Keep the "Loading address..." placeholder if address fetch fails
      end
    end)
  end
end
