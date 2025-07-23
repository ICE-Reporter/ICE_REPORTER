defmodule IceReporter.RateLimiter do
  @moduledoc """
  Rate limiter for tracking report submissions per IP address.
  Allows 3 reports per 10 minutes per IP before requiring hCaptcha.
  Also tracks report IDs temporarily for captcha failure cleanup.
  """
  use GenServer

  @max_reports 3
  @window_minutes 10
  @cleanup_interval :timer.minutes(5)

  def start_link(opts) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @doc """
  Check if IP address has exceeded rate limit.
  Returns {:ok, remaining_count} or {:rate_limited, next_reset_time}
  """
  def increment_count(ip_address) do
    GenServer.call(__MODULE__, {:increment, ip_address})
  end

  def check_rate_limit(ip_address) do
    GenServer.call(__MODULE__, {:check_rate_limit, ip_address})
  end

  @doc """
  Atomically check rate limit and increment if allowed.
  This prevents race conditions between check and increment operations.
  Returns {:ok, remaining_count} or {:rate_limited, next_reset_time}
  """
  def check_and_increment(ip_address) do
    GenServer.call(__MODULE__, {:check_and_increment, ip_address})
  end

  @doc """
  Record a new report submission for the given IP address.
  """
  def record_submission(ip_address) do
    GenServer.cast(__MODULE__, {:record_submission, ip_address})
  end

  @doc """
  Get current submission count for IP (for testing/debugging)
  """
  def get_submission_count(ip_address) do
    GenServer.call(__MODULE__, {:get_count, ip_address})
  end

  @doc """
  Reset rate limit for IP address (after successful captcha verification)
  """
  def reset_rate_limit(ip_address) do
    GenServer.cast(__MODULE__, {:reset, ip_address})
  end

  @doc """
  Track a report ID for potential cleanup on captcha failure
  """
  def track_report(fingerprint, report_id) do
    GenServer.cast(__MODULE__, {:track_report, fingerprint, report_id})
  end

  @doc """
  Remove all tracked reports for a fingerprint (on captcha failure)
  Returns list of report IDs that were removed
  """
  def cleanup_reports_for_fingerprint(fingerprint) do
    GenServer.call(__MODULE__, {:cleanup_reports, fingerprint})
  end

  @doc """
  Clear report tracking for a fingerprint (on captcha success)
  """
  def clear_report_tracking(fingerprint) do
    GenServer.cast(__MODULE__, {:clear_tracking, fingerprint})
  end

  ## Server Callbacks

  def init(_opts) do
    # Schedule periodic cleanup of expired entries
    schedule_cleanup()

    # State: %{
    #   rate_limits: %{ip_address => {count, window_start_time}},
    #   tracked_reports: %{fingerprint => {[report_ids], timestamp}}
    # }
    {:ok, %{rate_limits: %{}, tracked_reports: %{}}}
  end

  def handle_call({:check_rate_limit, ip_address}, _from, state) do
    now = System.system_time(:second)
    window_start = now - @window_minutes * 60

    case Map.get(state.rate_limits, ip_address) do
      nil ->
        # No previous submissions
        {:reply, {:ok, @max_reports}, state}

      {_count, timestamp} when timestamp < window_start ->
        # Window has expired, reset counter
        new_rate_limits = Map.delete(state.rate_limits, ip_address)
        new_state = %{state | rate_limits: new_rate_limits}
        {:reply, {:ok, @max_reports}, new_state}

      {count, timestamp} when count >= @max_reports ->
        # Rate limited
        next_reset = timestamp + @window_minutes * 60
        {:reply, {:rate_limited, next_reset}, state}

      {count, _timestamp} ->
        # Within limits
        remaining = @max_reports - count
        {:reply, {:ok, remaining}, state}
    end
  end

  def handle_call({:increment, ip_address}, _from, state) do
    now = System.system_time(:second)

    new_rate_limits =
      case Map.get(state.rate_limits, ip_address) do
        nil ->
          # First submission in window
          Map.put(state.rate_limits, ip_address, {1, now})

        {count, timestamp} ->
          # Increment count, keep original timestamp
          Map.put(state.rate_limits, ip_address, {count + 1, timestamp})
      end

    new_state = %{state | rate_limits: new_rate_limits}
    {:reply, :ok, new_state}
  end

  def handle_call({:check_and_increment, ip_address}, _from, state) do
    now = System.system_time(:second)
    window_start = now - @window_minutes * 60

    case Map.get(state.rate_limits, ip_address) do
      nil ->
        # No previous submissions - allow and increment
        new_rate_limits = Map.put(state.rate_limits, ip_address, {1, now})
        new_state = %{state | rate_limits: new_rate_limits}
        {:reply, {:ok, @max_reports - 1}, new_state}

      {_count, timestamp} when timestamp < window_start ->
        # Window has expired, reset counter to 1
        new_rate_limits = Map.put(state.rate_limits, ip_address, {1, now})
        new_state = %{state | rate_limits: new_rate_limits}
        {:reply, {:ok, @max_reports - 1}, new_state}

      {count, timestamp} when count >= @max_reports ->
        # Rate limited
        next_reset = timestamp + @window_minutes * 60
        {:reply, {:rate_limited, next_reset}, state}

      {count, timestamp} ->
        # Within limits - increment count
        new_count = count + 1
        new_rate_limits = Map.put(state.rate_limits, ip_address, {new_count, timestamp})
        new_state = %{state | rate_limits: new_rate_limits}
        remaining = @max_reports - new_count
        {:reply, {:ok, remaining}, new_state}
    end
  end

  def handle_call({:get_count, ip_address}, _from, state) do
    count =
      case Map.get(state.rate_limits, ip_address) do
        {count, _timestamp} -> count
        nil -> 0
      end

    {:reply, count, state}
  end

  def handle_call(:clear_all_state, _from, _state) do
    # Reset to initial state for testing
    initial_state = %{
      rate_limits: %{},
      tracked_reports: %{}
    }

    {:reply, :ok, initial_state}
  end

  def handle_call({:cleanup_reports, fingerprint}, _from, state) do
    case Map.get(state.tracked_reports, fingerprint) do
      {report_ids, _timestamp} ->
        # Remove tracking and return the report IDs for deletion
        new_tracked_reports = Map.delete(state.tracked_reports, fingerprint)
        new_state = %{state | tracked_reports: new_tracked_reports}
        {:reply, report_ids, new_state}

      nil ->
        # No reports tracked for this fingerprint
        {:reply, [], state}
    end
  end

  def handle_cast({:record_submission, ip_address}, state) do
    now = System.system_time(:second)

    new_rate_limits =
      case Map.get(state.rate_limits, ip_address) do
        nil ->
          # First submission in window
          Map.put(state.rate_limits, ip_address, {1, now})

        {count, timestamp} ->
          # Increment count, keep original timestamp
          Map.put(state.rate_limits, ip_address, {count + 1, timestamp})
      end

    new_state = %{state | rate_limits: new_rate_limits}
    {:noreply, new_state}
  end

  def handle_cast({:reset, ip_address}, state) do
    # Remove the IP from rate limiting (captcha verified)
    new_rate_limits = Map.delete(state.rate_limits, ip_address)
    new_state = %{state | rate_limits: new_rate_limits}
    {:noreply, new_state}
  end

  def handle_cast({:track_report, fingerprint, report_id}, state) do
    now = System.system_time(:second)

    new_tracked_reports =
      case Map.get(state.tracked_reports, fingerprint) do
        nil ->
          # First report for this fingerprint
          Map.put(state.tracked_reports, fingerprint, {[report_id], now})

        {existing_ids, timestamp} ->
          # Add to existing list
          Map.put(state.tracked_reports, fingerprint, {[report_id | existing_ids], timestamp})
      end

    new_state = %{state | tracked_reports: new_tracked_reports}
    {:noreply, new_state}
  end

  def handle_cast({:clear_tracking, fingerprint}, state) do
    # Remove tracking for this fingerprint (captcha succeeded)
    new_tracked_reports = Map.delete(state.tracked_reports, fingerprint)
    new_state = %{state | tracked_reports: new_tracked_reports}
    {:noreply, new_state}
  end

  def handle_info(:cleanup, state) do
    now = System.system_time(:second)
    window_start = now - @window_minutes * 60

    # Remove expired rate limit entries
    cleaned_rate_limits =
      state.rate_limits
      |> Enum.reject(fn {_ip, {_count, timestamp}} -> timestamp < window_start end)
      |> Map.new()

    # Remove expired tracked reports (after 30 minutes)
    tracked_reports_window = now - 30 * 60

    cleaned_tracked_reports =
      state.tracked_reports
      |> Enum.reject(fn {_fingerprint, {_report_ids, timestamp}} ->
        timestamp < tracked_reports_window
      end)
      |> Map.new()

    schedule_cleanup()
    {:noreply, %{rate_limits: cleaned_rate_limits, tracked_reports: cleaned_tracked_reports}}
  end

  defp schedule_cleanup do
    Process.send_after(self(), :cleanup, @cleanup_interval)
  end
end
