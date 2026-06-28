defmodule Florina.Auth.LoginRateLimiter do
  @moduledoc """
  A tiny in-memory (ETS) rate limiter for the operator-admin login endpoint, to
  blunt password-guessing without pulling in an external dependency.

  Keyed by client IP. After `@max_attempts` failed logins inside a rolling
  `@window_ms` window the key is blocked until the window expires; a successful
  login clears the key immediately. State is per-node and resets on restart —
  fine for this purpose (there is a single web node, and a restart is not an
  attacker-controllable event).

  Reads (`check/1`) hit the public ETS table directly; writes go through the
  GenServer so the read-modify-write of the counter can't race.
  """
  use GenServer
  require Logger

  @table :login_rate_limiter
  @max_attempts 5
  @window_ms 15 * 60 * 1000
  @sweep_ms 5 * 60 * 1000

  def start_link(opts) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @doc "`:ok` if the key may attempt a login, `{:error, :rate_limited}` if blocked."
  def check(key) do
    case :ets.lookup(@table, key) do
      [{^key, count, first_ms}]
      when count >= @max_attempts ->
        if now() - first_ms < @window_ms, do: {:error, :rate_limited}, else: :ok

      _ ->
        :ok
    end
  end

  @doc "Record a failed login attempt for the key."
  def record_failure(key), do: GenServer.call(__MODULE__, {:record_failure, key})

  @doc "Clear the key (call after a successful login)."
  def clear(key), do: GenServer.cast(__MODULE__, {:clear, key})

  @impl true
  def init(_opts) do
    table = :ets.new(@table, [:set, :public, :named_table, read_concurrency: true])
    schedule_sweep()
    {:ok, %{table: table}}
  end

  @impl true
  def handle_call({:record_failure, key}, _from, state) do
    now = now()

    case :ets.lookup(@table, key) do
      [{^key, count, first_ms}] when now - first_ms < @window_ms ->
        :ets.insert(@table, {key, count + 1, first_ms})

      _ ->
        :ets.insert(@table, {key, 1, now})
    end

    {:reply, :ok, state}
  end

  @impl true
  def handle_cast({:clear, key}, state) do
    :ets.delete(@table, key)
    {:noreply, state}
  end

  @impl true
  def handle_info(:sweep, state) do
    cutoff = now() - @window_ms
    # Drop any entry whose window started before the cutoff.
    :ets.select_delete(@table, [{{:_, :_, :"$1"}, [{:<, :"$1", cutoff}], [true]}])
    schedule_sweep()
    {:noreply, state}
  end

  defp schedule_sweep, do: Process.send_after(self(), :sweep, @sweep_ms)

  defp now, do: System.monotonic_time(:millisecond)
end
