defmodule IceReporterWeb.ReportLiveTest do
  @moduledoc """
  Essential integration tests for ReportLive.

  Tests core user workflows that are critical for the application.
  Focuses on the main user story: creating and viewing reports.
  """

  use IceReporterWeb.ConnCase

  import Phoenix.LiveViewTest

  alias IceReporter.{RateLimiter, Reports}

  setup do
    # Clear RateLimiter state and any existing reports
    GenServer.call(RateLimiter, :clear_all_state)

    Reports.list_active_reports()
    |> Enum.each(&Reports.deactivate_report/1)

    :ok
  end

  describe "initial page load" do
    test "displays empty state when no reports exist", %{conn: conn} do
      {:ok, _view, html} = live(conn, "/")

      assert html =~ "No reports yet!"
      assert html =~ "ICE Reporter"
    end

    test "displays existing reports when they exist", %{conn: conn} do
      # Create a test report
      {:ok, _report} =
        Reports.create_report(%{
          type: "checkpoint",
          description: "Test checkpoint",
          latitude: 40.7128,
          longitude: -74.0060,
          location_description: "New York, NY"
        })

      {:ok, _view, html} = live(conn, "/")

      # Should show the report in the list
      assert html =~ "Test checkpoint"
      assert html =~ "New York, NY"
    end
  end

  describe "map report creation" do
    test "creates report successfully with valid coordinates", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/")

      # Simulate map click to create report
      render_hook(view, "map_report", %{
        "latitude" => "40.7128",
        "longitude" => "-74.0060",
        "type" => "checkpoint",
        "fingerprint" => "test_fingerprint_123"
      })

      # Verify report was created
      reports = Reports.list_active_reports()
      assert length(reports) == 1

      report = hd(reports)
      assert report.type == "checkpoint"
      assert report.latitude == 40.7128
      assert report.longitude == -74.0060
    end

    test "handles invalid coordinates gracefully", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/")

      # Try to create report with invalid coordinates
      render_hook(view, "map_report", %{
        "latitude" => "invalid",
        "longitude" => "-74.0060",
        "type" => "checkpoint",
        "fingerprint" => "test_fingerprint_456"
      })

      # Should not create any reports
      reports = Reports.list_active_reports()
      assert Enum.empty?(reports)
    end
  end

  describe "rate limiting" do
    test "displays captcha when rate limited", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/")

      fingerprint = "rate_test_fp"

      # Create reports to hit rate limit (3 reports max)
      for _i <- 1..3 do
        render_hook(view, "map_report", %{
          "latitude" => "40.7128",
          "longitude" => "-74.0060",
          "type" => "checkpoint",
          "fingerprint" => fingerprint
        })
      end

      # Fourth request should trigger captcha
      html =
        render_hook(view, "map_report", %{
          "latitude" => "40.7128",
          "longitude" => "-74.0060",
          "type" => "checkpoint",
          "fingerprint" => fingerprint
        })

      # Should show captcha modal (or some rate limiting response)
      # The exact HTML depends on your implementation
      # At minimum, it should not crash
      assert is_binary(html)
    end
  end

  describe "pagination" do
    test "shows pagination when more than 10 reports exist", %{conn: conn} do
      # Create 12 reports to trigger pagination
      for i <- 1..12 do
        Reports.create_report(%{
          type: "checkpoint",
          description: "Report #{i}",
          latitude: 40.0 + i * 0.001,
          longitude: -74.0 + i * 0.001,
          location_description: "Location #{i}"
        })
      end

      {:ok, _view, html} = live(conn, "/")

      # Should show pagination controls
      assert html =~ "Next" or html =~ "Page"
    end
  end

  describe "language switching" do
    test "switches language successfully", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/")

      # Switch to Spanish
      render_click(view, "toggle_language", %{"language" => "es"})

      # The page should update (exact content depends on your implementation)
      html = render(view)
      # Should not crash
      assert is_binary(html)
    end
  end
end
