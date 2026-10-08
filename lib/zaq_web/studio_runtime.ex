defmodule ZaqWeb.StudioRuntime do
  @moduledoc """
  BO-local integration for manually enabling Jido Studio on this node.

  Studio starts under its own supervisor, never linked to the requesting LiveView.
  Enablement is not persisted and resets on node restart. Runtime shutdown is
  intentionally unavailable until upstream supports complete lifecycle cleanup.
  This controls Studio only, not ZAQ's Jido agent runtime.
  """

  alias Zaq.Accounts.User

  @doc "Returns whether the current BO user may enable and access Studio."
  @spec authorized?(User.t() | nil) :: boolean()
  def authorized?(%User{role: %{name: name}}) when name in ["admin", "super_admin"], do: true
  def authorized?(_user), do: false

  @doc "Returns the actual Studio runtime status on this BO node."
  @spec running?() :: boolean()
  def running?, do: is_pid(Process.whereis(JidoStudio.Runtime))

  @doc "Starts the supervised Studio runtime for an administrator, idempotently."
  @spec start(User.t() | nil) :: :ok | {:error, term()}
  def start(user) do
    if authorized?(user) do
      start_runtime()
    else
      {:error, :forbidden}
    end
  end

  defp start_runtime do
    case Supervisor.start_child(JidoStudio.Supervisor, JidoStudio.Runtime) do
      {:ok, _pid} -> :ok
      {:error, {:already_started, _pid}} -> :ok
      {:error, :already_present} -> restart_runtime()
      {:error, reason} -> {:error, reason}
    end
  catch
    :exit, _reason -> {:error, :unavailable}
  end

  defp restart_runtime do
    case Supervisor.restart_child(JidoStudio.Supervisor, JidoStudio.Runtime) do
      {:ok, _pid} -> :ok
      {:error, :running} -> :ok
      {:error, reason} -> {:error, reason}
    end
  end
end
