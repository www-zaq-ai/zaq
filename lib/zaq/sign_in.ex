defmodule Zaq.SignIn do
  @moduledoc """
  Interactive sign-in lifecycle above protocol-specific implementations.

  Implementations own authority, attempts, IO and durable completion. Consumers
  observe normalized challenges and receipts; opaque refs stay server-private.
  OAuth's HTTP device protocol and adapter-owned connection sessions remain distinct.
  """

  @type command ::
          {:begin, map()} | {:observe, term()} | {:confirm, term(), term()} | {:cancel, term()}
  @type result :: {:ok, map() | nil} | {:error, atom()}
  @callback sign_in(command(), term(), keyword()) :: result()

  @doc "Builds a normalized observation without interpreting protocol or owner values."
  def view(ref, attrs) do
    {:ok,
     Map.merge(
       %{
         ref: ref,
         status: "pending",
         challenge: nil,
         confirmation: nil,
         completion: nil,
         observe: true,
         interval_ms: 1_000,
         retry: :restart,
         dismiss: :detach
       },
       attrs
     )}
  end
end
