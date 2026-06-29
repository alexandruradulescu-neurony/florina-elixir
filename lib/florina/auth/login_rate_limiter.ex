defmodule Florina.Auth.LoginRateLimiter do
  @moduledoc """
  A tiny in-memory (ETS) rate limiter for the operator-admin login endpoint, to
  blunt password-guessing without pulling in an external dependency.

  Keyed by the submitted email (normalized) — NOT the client IP, because behind a
  reverse proxy every request shares one upstream IP and an IP key would lock out
  all admins at once. Per-email keying bounds guesses against each account.

  `check_and_count/1` does the read-and-increment as a single GenServer call, so
  concurrent login attempts can't all slip past the threshold before any is
  recorded (no check-then-act race). It counts *attempts* within a rolling
  `@window_ms`; a successful login clears the key immediately via `clear/1`.
  State is per-node and resets on restart — fine here (single web node).
  """
  use GenServer

  @table :login_rate_limiter
  @max_attempts 5
  @window_ms 15 * 60 * 1000
  @sweep_ms 5 * 60 * 1000

  def start_link(opts) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @doc """
  Atomically record one attempt for `key` and report whether it is allowed.
  Returns `:ok` if under the limit (and counts the attempt), or
  `{:error, :rate_limited}` once the window's attempts reach `@max_attempts`.
  """
  def check_and_count(key), do: GenServer.call(__MODULE__, {:check_and_count, key})

  @doc "Clear the key (call after a successful login)."
  def clear(key), do: GenServer.cast(__MODULE__, {:clear, key})

  @impl true
  def init(_opts) do
    :ets.new(@table, [:set, :named_table, read_concurrency: true])
    schedule_sweep()
    {:ok, %{}}
  end

  @impl true
  def handle_call({:check_and_count, key}, _from, state) do
    now = now()

    reply =
      case :ets.lookup(@table, key) do
        [{^key, count, first_ms}] when now - first_ms < @window_ms ->
          if count >= @max_attempts do
            {:error, :rate_limited}
          else
            :ets.insert(@table, {key, count + 1, first_ms})
            :ok
          end

        _ ->
          # Absent or expired window — start a fresh one.
          :ets.insert(@table, {key, 1, now})
          :ok
      end

    {:reply, reply, state}
  end

  @impl true
  def handle_cast({:clear, key}, state) do
    :ets.delete(@table, key)
    {:noreply, state}
  end

  @impl true
  def handle_info(:sweep, state) do
    cutoff = now() - @window_ms
    :ets.select_delete(@table, [{{:_, :_, :"$1"}, [{:<, :"$1", cutoff}], [true]}])
    schedule_sweep()
    {:noreply, state}
  end

  defp schedule_sweep, do: Process.send_after(self(), :sweep, @sweep_ms)

  defp now, do: System.monotonic_time(:millisecond)
end
