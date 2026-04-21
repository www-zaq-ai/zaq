defmodule Zaq.Agent.LLMRunnerBehaviour do
  @moduledoc false

  @callback run(keyword()) :: {:ok, map()} | {:error, String.t()}
  @callback content_result(map()) :: {:ok, String.t()} | {:error, String.t()}
end
