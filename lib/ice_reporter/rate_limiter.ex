defmodule IceReporter.RateLimiter do
  @moduledoc """
  Rate limiter for tracking report submissions per IP address.
  Allows 3 reports per 10 minutes per IP before requiring hCaptcha.
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

  ## Server Callbacks

  def init(_opts) do
    # Schedule periodic cleanup of expired entries
    schedule_cleanup()

    # State: %{ip_address => {count, window_start_time}}
    {:ok, %{}}
  end

  def handle_call({:check_rate_limit, ip_address}, _from, state) do
    now = System.system_time(:second)
    window_start = now - @window_minutes * 60

    case Map.get(state, ip_address) do
      nil ->
        # No previous submissions
        {:reply, {:ok, @max_reports}, state}

      {_count, timestamp} when timestamp < window_start ->
        # Window has expired, reset counter
        new_state = Map.delete(state, ip_address)
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

    new_state =
      case Map.get(state, ip_address) do
        nil ->
          # First submission in window
          Map.put(state, ip_address, {1, now})

        {count, timestamp} ->
          # Increment count, keep original timestamp
          Map.put(state, ip_address, {count + 1, timestamp})
      end

    {:reply, :ok, new_state}
  end

  def handle_call({:get_count, ip_address}, _from, state) do
    count =
      case Map.get(state, ip_address) do
        {count, _timestamp} -> count
        nil -> 0
      end

    {:reply, count, state}
  end

  def handle_cast({:record_submission, ip_address}, state) do
    now = System.system_time(:second)

    new_state =
      case Map.get(state, ip_address) do
        nil ->
          # First submission in window
          Map.put(state, ip_address, {1, now})

        {count, timestamp} ->
          # Increment count, keep original timestamp
          Map.put(state, ip_address, {count + 1, timestamp})
      end

    {:noreply, new_state}
  end

  def handle_cast({:reset, ip_address}, state) do
    # Remove the IP from rate limiting (captcha verified)
    new_state = Map.delete(state, ip_address)
    IO.puts("🔄 Rate limit reset for IP: #{ip_address}")
    {:noreply, new_state}
  end

  def handle_info(:cleanup, state) do
    now = System.system_time(:second)
    window_start = now - @window_minutes * 60

    # Remove expired entries
    cleaned_state =
      state
      |> Enum.reject(fn {_ip, {_count, timestamp}} -> timestamp < window_start end)
      |> Map.new()

    schedule_cleanup()
    {:noreply, cleaned_state}
  end

  defp schedule_cleanup do
    Process.send_after(self(), :cleanup, @cleanup_interval)
  end
end
