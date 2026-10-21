defmodule PictureRail.Web.PairingTest do
  use ExUnit.Case, async: true

  alias PictureRail.Web.Pairing

  @moduletag :tmp_dir

  defp start(dir, opts \\ []) do
    test = self()
    name = :"pairing_#{System.unique_integer([:positive])}"

    opts =
      Keyword.merge(
        [name: name, secret_file: Path.join(dir, "web_secret"), notify: &send(test, {:code, &1})],
        opts
      )

    start_supervised!({Pairing, opts}, id: name)
    assert_receive {:code, _first}
    name
  end

  defp wrong(code),
    do:
      code
      |> String.to_integer()
      |> Kernel.+(1)
      |> rem(100_000_000)
      |> Integer.to_string()
      |> String.pad_leading(8, "0")

  test "an 8-digit code; the right one pairs once, then there's a new one", %{tmp_dir: dir} do
    pairing = start(dir)
    code = Pairing.code(pairing)
    assert code =~ ~r/^\d{8}$/

    # as the frame shows it, in two halves
    {first, second} = String.split_at(code, 4)
    assert Pairing.verify(" #{first} #{second} ", pairing) == :ok
    assert_receive {:code, new}
    assert new == Pairing.code(pairing)
    # (one time in a million the new code is the same)
    if new != code, do: assert(Pairing.verify(code, pairing) == {:error, :wrong})
  end

  test "four wrong tries leave the code; the fifth changes it and locks pairing", %{tmp_dir: dir} do
    pairing = start(dir)
    code = Pairing.code(pairing)

    for _ <- 1..4, do: assert(Pairing.verify(wrong(code), pairing) == {:error, :wrong})
    assert Pairing.code(pairing) == code
    refute_received {:code, _}

    assert Pairing.verify(wrong(code), pairing) == {:error, :wrong}
    assert_receive {:code, new}
    assert Pairing.verify(new, pairing) == {:error, :locked}
  end

  test "once the lockout is over the new code works", %{tmp_dir: dir} do
    pairing = start(dir, lockout_ms: 0)
    code = Pairing.code(pairing)
    for _ <- 1..5, do: Pairing.verify(wrong(code), pairing)
    assert_receive {:code, new}
    assert Pairing.verify(new, pairing) == :ok
  end

  test "forgetting devices lifts a lockout", %{tmp_dir: dir} do
    pairing = start(dir)
    code = Pairing.code(pairing)
    for _ <- 1..5, do: Pairing.verify(wrong(code), pairing)
    assert_receive {:code, new}
    assert Pairing.verify(new, pairing) == {:error, :locked}

    :ok = Pairing.forget(pairing)
    assert_receive {:code, after_forget}
    assert Pairing.verify(after_forget, pairing) == :ok
  end

  test "lockouts start over after a quiet spell, counted from the lockout's end", %{
    tmp_dir: dir
  } do
    # a lockout that ends at once, and a quiet spell of 50 ms
    pairing = start(dir, lockout_ms: 0, quiet_ms: 50)
    rounds = fn -> :sys.get_state(pairing).rounds end

    for _ <- 1..5, do: Pairing.verify(wrong(Pairing.code(pairing)), pairing)
    assert rounds.() == 1
    for _ <- 1..5, do: Pairing.verify(wrong(Pairing.code(pairing)), pairing)
    assert rounds.() == 2

    Process.sleep(60)
    Pairing.verify(wrong(Pairing.code(pairing)), pairing)
    assert rounds.() == 0
  end

  test "forgetting says so when the old secret can't be replaced or removed", %{tmp_dir: dir} do
    locked = Path.join(dir, "locked")
    File.mkdir_p!(locked)
    pairing = start(dir, secret_file: Path.join(locked, "web_secret"))
    old = Pairing.secret_key_base(pairing)

    # neither a new file nor removing the old one (a read-only filesystem)
    File.chmod!(locked, 0o500)
    on_exit(fn -> File.chmod(locked, 0o700) end)

    assert Pairing.forget(pairing) == {:error, :not_saved}
    # ended for now all the same
    refute Pairing.secret_key_base(pairing) == old

    # the :pairing controller shows what forgetting returned
    failed = %{forget: fn -> Pairing.forget(pairing) end}

    assert PictureRail.App.Pairing.forget(nil, %{forget_failed?: false}, %{}, failed) ==
             %{forget_failed?: true}

    worked = %{forget: fn -> :ok end}

    assert PictureRail.App.Pairing.forget(nil, %{forget_failed?: true}, %{}, worked) ==
             %{forget_failed?: false}
  end

  test "the code changes by itself", %{tmp_dir: dir} do
    _pairing = start(dir, code_ms: 20)
    assert_receive {:code, _next}, 500
  end

  test "the secret is kept private and across restarts; forget replaces it", %{tmp_dir: dir} do
    pairing = start(dir)
    file = Path.join(dir, "web_secret")
    secret = Pairing.secret_key_base(pairing)
    assert byte_size(secret) >= 64
    assert File.read!(file) == secret
    assert Bitwise.band(File.stat!(file).mode, 0o777) == 0o600

    stop_supervised!(pairing)
    pairing = start(dir)
    assert Pairing.secret_key_base(pairing) == secret

    assert Pairing.forget(pairing) == :ok
    assert_receive {:code, _}
    refute Pairing.secret_key_base(pairing) == secret
    assert File.read!(file) == Pairing.secret_key_base(pairing)
  end
end
