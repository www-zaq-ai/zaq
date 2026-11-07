defmodule Zaq.Contracts.ActionInvocation do
  @moduledoc """
  Identity mapping for nested ZAQ Action invocations.

  Native root IDs remain opaque and unchanged. Each child adds a UUID segment to
  the explicit path; its ID encodes the root with unpadded base64url followed by
  those segments, preserving their spelling. This pure contract neither allocates
  invocations nor establishes permission, workflow ownership or event admission.
  """

  @doc "Returns the identity of a nonempty invocation path without normalizing it."
  @spec id([binary(), ...]) :: binary()
  def id([root]), do: root

  def id([root | segments]),
    do: Enum.join(["zaq", Base.url_encode64(root, padding: false) | segments], ".")

  @doc "Checks a nonempty root and UUID child segments against their exact identity."
  @spec valid_path?(term(), term()) :: boolean()
  def valid_path?([root | segments] = path, id) when is_binary(root) and root != "" do
    Enum.all?(segments, &match?({:ok, _}, Ecto.UUID.cast(&1))) and id(path) == id
  end

  def valid_path?(_path, _id), do: false
end
