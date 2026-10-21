defmodule PictureRail.Web.Pairing do
  @moduledoc """
  Pairing a phone or laptop with the settings web page.

  The frame's Setup page shows an 8-digit code (and a QR code carrying it).
  Entering it on the web page starts a session: a signed cookie, good for
  12 hours. The code changes once it's used, after 5 wrong tries, and
  every 30 minutes. After 5 wrong tries pairing is refused for a minute,
  doubling with each further round (up to an hour), so the code can't be
  guessed by trying them all; the rounds start over after an hour without
  a wrong code.

  Sessions are signed with a secret kept in `<data_dir>/web_secret`, made
  on the first start (mode 0600, `PictureRail.PrivateFile`). `forget/1`
  replaces it, which ends every session ("Forget paired devices" on the
  frame), and lifts a lockout: whoever taps it is at the frame. If the new
  secret can't be saved the old file is removed, so a restart can't bring
  the forgotten sessions back.

  Reports the code to the `:pairing` controller.
  """
  use GenServer

  require Logger

  alias PictureRail.{Paths, PrivateFile}

  @code_ms 30 * 60_000
  @tries 5
  @lockout_ms 60_000
  @max_lockout_ms 3_600_000
  @secret_bytes 64
  @digits 8

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []) do
    {name, opts} = Keyword.pop(opts, :name, __MODULE__)
    GenServer.start_link(__MODULE__, opts, name: name)
  end

  @doc "The code to show on the frame."
  @spec code(GenServer.server()) :: String.t()
  def code(server \\ __MODULE__), do: GenServer.call(server, :code)

  @doc """
  Check a code someone entered: `:ok` (and a new code), `{:error, :wrong}`,
  or `{:error, :locked}` while pairing is refused after too many tries.
  """
  @spec verify(String.t(), GenServer.server()) :: :ok | {:error, :wrong | :locked}
  def verify(code, server \\ __MODULE__) when is_binary(code),
    do: GenServer.call(server, {:verify, code})

  @doc "The secret sessions are signed with (`conn.secret_key_base`)."
  @spec secret_key_base(GenServer.server()) :: String.t()
  def secret_key_base(server \\ __MODULE__), do: GenServer.call(server, :secret)

  @doc "End every session: a new secret, a new code, and no lockout."
  @spec forget(GenServer.server()) :: :ok
  def forget(server \\ __MODULE__), do: GenServer.call(server, :forget)

  # -- GenServer --

  @impl GenServer
  def init(opts) do
    file =
      Keyword.get_lazy(opts, :secret_file, fn -> Path.join(Paths.data_dir(), "web_secret") end)

    state = %{
      file: file,
      secret: load_secret(file),
      notify: Keyword.get(opts, :notify, &notify_app/1),
      code_ms: Keyword.get(opts, :code_ms, @code_ms),
      lockout_ms: Keyword.get(opts, :lockout_ms, @lockout_ms),
      quiet_ms: Keyword.get(opts, :quiet_ms, @max_lockout_ms),
      code: nil,
      timer: nil,
      failures: 0,
      rounds: 0,
      locked_until: nil,
      last_wrong: nil
    }

    {:ok, new_code(state)}
  end

  @impl GenServer
  def handle_call(:code, _from, state), do: {:reply, state.code, state}
  def handle_call(:secret, _from, state), do: {:reply, state.secret, state}

  def handle_call(:forget, _from, state) do
    Logger.info("Web: paired devices forgotten")
    secret = new_secret(state.file)
    state = %{state | secret: secret, failures: 0, rounds: 0, locked_until: nil}
    {:reply, :ok, new_code(state)}
  end

  def handle_call({:verify, code}, _from, state) do
    state = forgive(state)

    cond do
      locked?(state) ->
        {:reply, {:error, :locked}, state}

      Plug.Crypto.secure_compare(String.replace(code, ~r/\s/, ""), state.code) ->
        Logger.info("Web: a device paired")
        {:reply, :ok, new_code(%{state | failures: 0, rounds: 0, locked_until: nil})}

      state.failures + 1 >= @tries ->
        lockout = Kernel.min(state.lockout_ms * Integer.pow(2, state.rounds), @max_lockout_ms)
        Logger.warning("Web: #{@tries} wrong pairing codes, pairing refused for #{lockout} ms")

        state = %{
          state
          | failures: 0,
            rounds: state.rounds + 1,
            locked_until: now() + lockout,
            last_wrong: now()
        }

        {:reply, {:error, :wrong}, new_code(state)}

      true ->
        {:reply, {:error, :wrong}, %{state | failures: state.failures + 1, last_wrong: now()}}
    end
  end

  @impl GenServer
  def handle_info({:rotate, ref}, %{timer: {ref, _timer}} = state),
    do: {:noreply, new_code(state)}

  def handle_info(_message, state), do: {:noreply, state}

  # -- Code --

  # An hour without a wrong code, counted from the end of any lockout:
  # the lockouts start over from a minute.
  defp forgive(%{last_wrong: at} = state) when is_integer(at) do
    if now() - Kernel.max(at, state.locked_until || at) > state.quiet_ms,
      do: %{state | failures: 0, rounds: 0, last_wrong: nil},
      else: state
  end

  defp forgive(state), do: state

  defp locked?(%{locked_until: nil}), do: false
  defp locked?(%{locked_until: until}), do: now() < until

  defp new_code(state) do
    with {_ref, timer} <- state.timer, do: Process.cancel_timer(timer)

    code =
      :crypto.strong_rand_bytes(6)
      |> :binary.decode_unsigned()
      |> rem(Integer.pow(10, @digits))
      |> Integer.to_string()
      |> String.pad_leading(@digits, "0")

    ref = make_ref()
    timer = Process.send_after(self(), {:rotate, ref}, state.code_ms)
    state.notify.(code)
    %{state | code: code, timer: {ref, timer}}
  end

  defp now, do: System.monotonic_time(:millisecond)

  # -- Secret --

  defp load_secret(file) do
    with {:ok, text} <- File.read(file),
         {:ok, secret} <- Base.decode64(String.trim(text)),
         true <- byte_size(secret) >= @secret_bytes do
      String.trim(text)
    else
      _ -> new_secret(file)
    end
  end

  # Base 64: Plug wants a secret of at least 64 bytes, and text.
  defp new_secret(file) do
    secret = Base.encode64(:crypto.strong_rand_bytes(@secret_bytes))

    case PrivateFile.write(file, secret) do
      :ok ->
        :ok

      {:error, reason} ->
        # the old one mustn't come back on a restart
        _ = File.rm(file)

        Logger.error(
          "Web: couldn't save the session secret (#{inspect(reason)}); sessions end on restart"
        )
    end

    secret
  end

  defp notify_app(code) do
    if Process.whereis(PictureRail.App),
      do: Solve.dispatch(PictureRail.App, :pairing, :code, code)

    :ok
  end
end
