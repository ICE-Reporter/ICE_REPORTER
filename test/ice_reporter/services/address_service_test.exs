defmodule IceReporter.Services.AddressServiceTest do
  @moduledoc """
  Unit tests for AddressService using Bypass for HTTP mocking.

  These tests mock external API calls to ensure fast, reliable tests
  that don't depend on external services being available.
  """

  use ExUnit.Case, async: true

  alias IceReporter.Services.AddressService

  setup do
    # Start Bypass server for mocking HTTP calls
    bypass = Bypass.open()

    # Configure AddressService to use our mock server
    Application.put_env(:ice_reporter, :nominatim_base_url, "http://localhost:#{bypass.port}")

    # Reset to default after test
    on_exit(fn ->
      Application.delete_env(:ice_reporter, :nominatim_base_url)
    end)

    {:ok, bypass: bypass}
  end

  describe "get_address_from_coords/2" do
    test "returns formatted address on successful API response", %{bypass: bypass} do
      # Mock successful Nominatim response
      Bypass.expect(bypass, "GET", "/reverse", fn conn ->
        # Verify basic parameters are present
        assert conn.query_string =~ "format=json"
        assert conn.query_string =~ "lat=40.7128"
        assert conn.query_string =~ "lon=-74.006"

        response = %{
          "display_name" => "123 Main Street, New York, NY 10001, United States",
          "address" => %{
            "house_number" => "123",
            "road" => "Main Street",
            "city" => "New York",
            "state" => "New York",
            "postcode" => "10001",
            "country" => "United States"
          }
        }

        conn
        |> Plug.Conn.put_resp_header("content-type", "application/json")
        |> Plug.Conn.resp(200, Jason.encode!(response))
      end)

      result = AddressService.get_address_from_coords(40.7128, -74.0060)
      assert result == "123 Main Street, New York, New York 10001, United States"
    end

    test "returns coordinate fallback on API error", %{bypass: bypass} do
      # Mock API error response (allow retries with Bypass.expect)
      Bypass.expect(bypass, "GET", "/reverse", fn conn ->
        Plug.Conn.resp(conn, 500, "Internal Server Error")
      end)

      result = AddressService.get_address_from_coords(0.0, 0.0)
      assert result == "Location coordinates: 0.0, 0.0"
    end

    test "returns formatted address when display_name missing but address present", %{
      bypass: bypass
    } do
      # Mock response without display_name but with address components
      Bypass.expect(bypass, "GET", "/reverse", fn conn ->
        response = %{"address" => %{"city" => "New York"}}

        conn
        |> Plug.Conn.put_resp_header("content-type", "application/json")
        |> Plug.Conn.resp(200, Jason.encode!(response))
      end)

      result = AddressService.get_address_from_coords(40.7128, -74.0060)
      assert result == "New York"
    end
  end

  describe "search_addresses/1" do
    test "returns search results on successful API response", %{bypass: bypass} do
      # Mock successful search response
      Bypass.expect(bypass, "GET", "/search", fn conn ->
        assert conn.query_string =~ "format=json"
        assert conn.query_string =~ "q=New+York"

        response = [
          %{
            "lat" => "40.7127753",
            "lon" => "-74.0059728",
            "display_name" => "New York, NY, United States",
            "address" => %{
              "city" => "New York",
              "state" => "New York",
              "country" => "United States"
            }
          },
          %{
            "lat" => "40.758896",
            "lon" => "-73.9873197",
            "display_name" => "Times Square, New York, NY",
            "address" => %{
              "tourism" => "Times Square",
              "city" => "New York",
              "state" => "New York"
            }
          }
        ]

        conn
        |> Plug.Conn.put_resp_header("content-type", "application/json")
        |> Plug.Conn.resp(200, Jason.encode!(response))
      end)

      {:ok, results} = AddressService.search_addresses("New York")

      assert length(results) == 2

      [first, second] = results
      assert first.lat == 40.7127753
      assert first.lng == -74.0059728
      assert first.address == "New York, New York, United States"

      assert second.lat == 40.758896
      assert second.lng == -73.9873197
      assert second.address == "Times Square"
    end

    test "returns error on API failure", %{bypass: bypass} do
      # Mock API error (allow retries)
      Bypass.expect(bypass, "GET", "/search", fn conn ->
        Plug.Conn.resp(conn, 503, "Service Unavailable")
      end)

      result = AddressService.search_addresses("New York")
      assert {:error, _reason} = result
    end

    test "handles empty query gracefully", %{bypass: bypass} do
      # Empty query still makes HTTP call but gets error response
      Bypass.expect(bypass, "GET", "/search", fn conn ->
        Plug.Conn.resp(conn, 400, "Bad Request")
      end)

      result = AddressService.search_addresses("")
      assert {:error, _reason} = result
    end

    test "handles standard search response format", %{bypass: bypass} do
      # Mock normal API response with valid coordinates
      Bypass.expect(bypass, "GET", "/search", fn conn ->
        response = [
          %{
            "lat" => "40.0",
            "lon" => "-74.0",
            "display_name" => "Valid Location"
          }
        ]

        conn
        |> Plug.Conn.put_resp_header("content-type", "application/json")
        |> Plug.Conn.resp(200, Jason.encode!(response))
      end)

      {:ok, results} = AddressService.search_addresses("test")
      assert length(results) == 1
      assert hd(results).lat == 40.0
    end
  end
end
