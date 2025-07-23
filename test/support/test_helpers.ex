defmodule IceReporter.TestHelpers do
  @moduledoc """
  Helper functions for tests.

  This module provides utilities for setting up test data,
  mocking external services, and common test patterns.
  """

  alias IceReporter.{Repo, Report}
  alias IceReporter.Services.ReportService

  @doc """
  Creates a valid report with the given attributes.
  """
  def create_report(attrs \\ %{}) do
    attrs
    |> valid_report_attrs()
    |> IceReporter.Reports.create_report()
  end

  @doc """
  Inserts a report directly into the database (bypassing business logic).
  """
  def insert_report(attrs \\ %{}) do
    attrs
    |> valid_report_attrs()
    |> then(fn attrs ->
      %Report{}
      |> Report.changeset(attrs)
      |> Repo.insert!()
    end)
  end

  @doc """
  Returns valid attributes for creating a report.
  """
  def valid_report_attrs(attrs \\ %{}) do
    defaults = %{
      type: "checkpoint",
      description: "Test report",
      latitude: 40.7128,
      longitude: -74.0060,
      location_description: "New York, NY",
      is_active: true,
      expires_at: DateTime.utc_now() |> DateTime.add(4, :hour)
    }

    Map.merge(defaults, attrs)
  end

  @doc """
  Creates multiple reports for pagination testing.
  """
  def create_reports(count, attrs \\ %{}) do
    for i <- 1..count do
      attrs
      |> Map.merge(%{
        description: "Test report #{i}",
        latitude: 40.0 + i * 0.001,
        longitude: -74.0 + i * 0.001
      })
      |> create_report()
    end
  end

  @doc """
  Clears all reports from the database.
  """
  def clear_all_reports do
    Repo.delete_all(Report)
  end

  @doc """
  Sets up a rate-limited scenario for testing.
  """
  def setup_rate_limit(fingerprint) do
    # Create 3 reports to hit the rate limit
    for i <- 1..3 do
      ReportService.create_report_with_validation(
        %{
          latitude: "40.#{i}",
          longitude: "-74.00#{i}",
          type: "checkpoint"
        },
        fingerprint
      )
    end
  end

  @doc """
  Mock HTTP response for external API calls.
  """
  def mock_nominatim_response(coordinates \\ {40.7128, -74.0060}) do
    {lat, lng} = coordinates

    %{
      "lat" => to_string(lat),
      "lon" => to_string(lng),
      "display_name" => "Mocked Address, New York, NY, United States",
      "address" => %{
        "house_number" => "123",
        "road" => "Main Street",
        "city" => "New York",
        "state" => "New York",
        "postcode" => "10001",
        "country" => "United States"
      }
    }
  end

  @doc """
  Mock hCaptcha verification response.
  """
  def mock_hcaptcha_success do
    %{"success" => true}
  end

  def mock_hcaptcha_failure do
    %{
      "success" => false,
      "error-codes" => ["invalid-input-response"]
    }
  end

  @doc """
  Waits for a PubSub message with timeout.
  """
  defmacro assert_receive_pubsub(topic, message, timeout \\ 1000) do
    quote do
      Phoenix.PubSub.subscribe(IceReporter.PubSub, unquote(topic))
      assert_receive unquote(message), unquote(timeout)
    end
  end

  @doc """
  Creates a test socket for LiveView tests.
  """
  def build_conn_with_session(conn \\ Phoenix.ConnTest.build_conn()) do
    conn
    |> Plug.Test.init_test_session(%{})
  end

  @doc """
  Simulates time passage for rate limiter tests.
  """
  def simulate_time_passage(minutes) do
    :timer.sleep(minutes * 1000)
  end

  @doc """
  Asserts that an element exists in LiveView HTML.
  """
  defmacro assert_html_contains(html, content) do
    quote do
      assert unquote(html) =~ unquote(content)
    end
  end

  @doc """
  Asserts that an element does not exist in LiveView HTML.
  """
  defmacro refute_html_contains(html, content) do
    quote do
      refute unquote(html) =~ unquote(content)
    end
  end
end
