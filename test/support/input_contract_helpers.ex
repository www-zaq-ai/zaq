defmodule Zaq.InputContractHelpers do
  @moduledoc """
  Readers for an `InputContract` verdict in tests.

  The verdict is one list of errors, each carrying its own `code`, so a test that
  cares about a particular kind of problem asks for that kind rather than reaching
  into a bucket. Paths come back as the segment lists the verdict carries.
  """

  @doc "Paths the payload did not supply."
  def missing(verdict), do: for(%{code: :required, path: path} <- verdict.errors, do: path)

  @doc "Paths the payload supplied with a value some step refuses."
  def refused(verdict),
    do: for(%{code: code, path: path} <- verdict.errors, code != :required, do: path)

  @doc "Every error's code, in order."
  def codes(verdict), do: Enum.map(verdict.errors, & &1.code)

  @doc "Every error's message, in order."
  def messages(verdict), do: Enum.map(verdict.errors, & &1.message)

  @doc "The one error reported at `path`, or nil."
  def error_at(verdict, path), do: Enum.find(verdict.errors, &(&1.path == path))
end
