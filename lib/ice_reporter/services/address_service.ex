defmodule IceReporter.Services.AddressService do
  @moduledoc """
  Service for handling address resolution and search functionality.

  This module encapsulates all external API interactions with OpenStreetMap's
  Nominatim service for geocoding and reverse geocoding operations.
  """

  @type coordinate :: float()
  @type search_result :: %{lat: coordinate(), lng: coordinate(), address: String.t()}

  # Default base URL for production
  @default_base_url "https://nominatim.openstreetmap.org"

  # Get base URL from config or use default
  defp base_url do
    Application.get_env(:ice_reporter, :nominatim_base_url, @default_base_url)
  end

  @doc """
  Fetches a formatted address for the given coordinates.

  ## Parameters
    - lat: Latitude coordinate
    - lng: Longitude coordinate
    
  ## Returns
    - String: Formatted address or fallback coordinate string
  """
  @spec get_address_from_coords(coordinate(), coordinate()) :: String.t()
  def get_address_from_coords(lat, lng) do
    url = "#{base_url()}/reverse"

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
           receive_timeout: 15_000,
           retry: :transient,
           max_retries: 2
         ) do
      {:ok, %{status: 200, body: result}} ->
        format_address(result)

      {:ok, %{status: _status, body: _body}} ->
        "Location coordinates: #{lat}, #{lng}"

      {:error, _reason} ->
        "Location coordinates: #{lat}, #{lng}"
    end
  end

  @doc """
  Searches for addresses matching the given query.

  ## Parameters
    - query: Search string
    
  ## Returns
    - {:ok, [search_result()]} on success
    - {:error, String.t()} on failure
  """
  @spec search_addresses(String.t()) :: {:ok, [search_result()]} | {:error, String.t()}
  def search_addresses(query) do
    url = "#{base_url()}/search"

    params = [
      format: "json",
      q: query,
      limit: 8,
      countrycodes: "us",
      addressdetails: 1,
      featuretype: "settlement,highway,natural,leisure,amenity,tourism,building"
    ]

    case Req.get(url,
           params: params,
           headers: [{"User-Agent", "IceReporter/1.0"}],
           receive_timeout: 15_000,
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
          |> Enum.take(5)

        {:ok, suggestions}

      {:ok, %{status: _status, body: _body}} ->
        {:error, "Failed to search addresses"}

      {:error, _reason} ->
        {:error, "Network error during address search"}
    end
  end

  # Private helper function to format address from Nominatim response
  defp format_address(result) do
    address = result["address"] || %{}

    # Check for landmarks first
    case get_landmark(address) do
      nil -> format_structured_address(address, result)
      landmark -> landmark
    end
  end

  defp get_landmark(address) do
    address["tourism"] ||
      address["leisure"] ||
      address["amenity"] ||
      address["building"] ||
      address["shop"] ||
      address["office"] ||
      address["natural"] ||
      address["historic"]
  end

  defp format_structured_address(address, result) do
    parts =
      []
      |> add_street_address(address)
      |> add_city(address)
      |> add_state_zip(address)
      |> add_country(address)

    case parts do
      [] -> format_display_name(result)
      parts -> parts |> Enum.reverse() |> Enum.join(", ")
    end
  end

  defp add_street_address(parts, address) do
    street_parts = [address["house_number"], address["road"]] |> Enum.filter(& &1)

    case street_parts do
      [] -> parts
      parts_list -> [Enum.join(parts_list, " ") | parts]
    end
  end

  defp add_city(parts, address) do
    city = address["city"] || address["town"] || address["village"] || address["hamlet"]

    case city do
      nil -> parts
      city_name -> [city_name | parts]
    end
  end

  defp add_state_zip(parts, address) do
    state_parts = [address["state"], address["postcode"]] |> Enum.filter(& &1)

    case state_parts do
      [] -> parts
      parts_list -> [Enum.join(parts_list, " ") | parts]
    end
  end

  defp add_country(parts, address) do
    case address["country"] do
      nil -> parts
      country -> [country | parts]
    end
  end

  defp format_display_name(result) do
    display_name = result["display_name"] || "Unknown Location"

    display_name
    |> String.split(",")
    |> Enum.take(3)
    |> Enum.map_join(", ", &String.trim/1)
  end
end
