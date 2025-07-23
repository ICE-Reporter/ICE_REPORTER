defmodule IceReporter.RateLimiterTest do
  @moduledoc """
  Essential tests for RateLimiter GenServer.

  Tests core rate limiting behavior that's critical for security.
  Only tests the public API, not internal state management.
  """

  # GenServer tests should not be async
  use ExUnit.Case, async: false

  alias IceReporter.RateLimiter

  setup do
    # Clear RateLimiter state before each test
    GenServer.call(RateLimiter, :clear_all_state)
    :ok
  end

  describe "check_and_increment/1" do
    test "allows requests within rate limit" do
      ip = "192.168.1.100"

      # First 3 requests should succeed
      assert {:ok, 2} = RateLimiter.check_and_increment(ip)
      assert {:ok, 1} = RateLimiter.check_and_increment(ip)
      assert {:ok, 0} = RateLimiter.check_and_increment(ip)
    end

    test "blocks requests when rate limit exceeded" do
      ip = "192.168.1.101"

      # Use up the rate limit
      {:ok, _} = RateLimiter.check_and_increment(ip)
      {:ok, _} = RateLimiter.check_and_increment(ip)
      {:ok, _} = RateLimiter.check_and_increment(ip)

      # Fourth request should be rate limited
      assert {:rate_limited, reset_time} = RateLimiter.check_and_increment(ip)
      assert is_integer(reset_time)
      assert reset_time > System.system_time(:second)
    end

    test "handles different IPs independently" do
      ip1 = "192.168.1.102"
      ip2 = "192.168.1.103"

      # Use up limit for ip1
      {:ok, _} = RateLimiter.check_and_increment(ip1)
      {:ok, _} = RateLimiter.check_and_increment(ip1)
      {:ok, _} = RateLimiter.check_and_increment(ip1)

      # ip1 should be rate limited
      assert {:rate_limited, _} = RateLimiter.check_and_increment(ip1)

      # ip2 should still work
      assert {:ok, 2} = RateLimiter.check_and_increment(ip2)
    end
  end

  describe "reset_rate_limit/1" do
    test "resets rate limit for specific IP" do
      ip = "192.168.1.104"

      # Exceed rate limit
      {:ok, _} = RateLimiter.check_and_increment(ip)
      {:ok, _} = RateLimiter.check_and_increment(ip)
      {:ok, _} = RateLimiter.check_and_increment(ip)
      assert {:rate_limited, _} = RateLimiter.check_and_increment(ip)

      # Reset should allow requests again
      :ok = RateLimiter.reset_rate_limit(ip)
      assert {:ok, 2} = RateLimiter.check_and_increment(ip)
    end
  end
end
