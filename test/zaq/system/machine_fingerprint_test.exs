defmodule Zaq.System.MachineFingerprintTest do
  use ExUnit.Case, async: true

  alias Zaq.System.MachineFingerprint

  test "returns a string of at least 8 characters" do
    assert byte_size(MachineFingerprint.get()) >= 8
  end

  test "is stable across calls" do
    assert MachineFingerprint.get() == MachineFingerprint.get()
  end

  test "is lowercase hex" do
    assert MachineFingerprint.get() =~ ~r/^[0-9a-f]+$/
  end
end
