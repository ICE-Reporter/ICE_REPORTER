defmodule IceReporter.ReportsTest do
  @moduledoc """
  Essential tests for the Reports context.

  Tests core CRUD operations and pagination that are critical
  for the application to function properly.
  """

  use IceReporter.DataCase

  alias IceReporter.Reports

  describe "create_report/1" do
    test "creates report with valid attributes" do
      attrs = %{
        type: "checkpoint",
        description: "Test checkpoint",
        latitude: 40.7128,
        longitude: -74.0060,
        location_description: "New York, NY"
      }

      assert {:ok, report} = Reports.create_report(attrs)
      assert report.type == "checkpoint"
      assert report.description == "Test checkpoint"
      assert report.latitude == 40.7128
      assert report.longitude == -74.0060
      assert report.is_active == true

      # Check expires_at is set (within 5 seconds of expected)
      expected_expiry = DateTime.utc_now() |> DateTime.add(4, :hour)
      assert DateTime.diff(report.expires_at, expected_expiry, :second) |> abs() < 5
    end

    test "fails with invalid attributes" do
      attrs = %{
        type: "invalid_type",
        latitude: "invalid_lat",
        # Invalid longitude
        longitude: -200.0
      }

      assert {:error, changeset} = Reports.create_report(attrs)
      assert changeset.valid? == false
      assert "is invalid" in errors_on(changeset).type
    end
  end

  describe "list_active_reports/0" do
    test "returns empty list when no reports exist" do
      assert Reports.list_active_reports() == []
    end

    test "returns only active, non-expired reports" do
      # Create active report
      {:ok, active_report} =
        Reports.create_report(%{
          type: "checkpoint",
          description: "Active report",
          latitude: 40.7128,
          longitude: -74.0060,
          location_description: "NYC",
          is_active: true
        })

      # Create inactive report
      Reports.create_report(%{
        type: "raid",
        description: "Inactive report",
        latitude: 40.7128,
        longitude: -74.0060,
        location_description: "NYC",
        is_active: false
      })

      reports = Reports.list_active_reports()
      assert length(reports) == 1
      assert hd(reports).id == active_report.id
    end
  end

  describe "list_active_reports_paginated/2" do
    setup do
      # Create exactly 15 test reports for pagination testing
      for i <- 1..15 do
        Reports.create_report(%{
          type: "checkpoint",
          description: "Test report #{i}",
          latitude: 40.0 + i * 0.001,
          longitude: -74.0 + i * 0.001,
          location_description: "Location #{i}"
        })
      end

      :ok
    end

    test "returns correct pagination for first page" do
      result = Reports.list_active_reports_paginated(1, 10)

      assert result.page == 1
      assert result.per_page == 10
      assert result.total_count == 15
      assert result.total_pages == 2
      assert result.has_previous == false
      assert result.has_next == true
      assert length(result.reports) == 10
    end

    test "returns correct pagination for second page" do
      result = Reports.list_active_reports_paginated(2, 10)

      assert result.page == 2
      assert result.has_previous == true
      assert result.has_next == false
      # Remaining reports
      assert length(result.reports) == 5
    end
  end

  describe "update_report_address/2" do
    test "updates report address successfully" do
      {:ok, report} =
        Reports.create_report(%{
          type: "checkpoint",
          description: "Test report",
          latitude: 40.7128,
          longitude: -74.0060,
          location_description: "Loading address..."
        })

      new_address = "123 Main St, New York, NY"

      assert {:ok, updated_report} = Reports.update_report_address(report, new_address)
      assert updated_report.location_description == new_address
      assert updated_report.id == report.id
    end
  end

  describe "deactivate_report/1" do
    test "deactivates an active report" do
      {:ok, report} =
        Reports.create_report(%{
          type: "checkpoint",
          description: "Test report",
          latitude: 40.7128,
          longitude: -74.0060,
          location_description: "NYC",
          is_active: true
        })

      assert {:ok, updated_report} = Reports.deactivate_report(report)
      assert updated_report.is_active == false
      assert updated_report.id == report.id
    end
  end
end
