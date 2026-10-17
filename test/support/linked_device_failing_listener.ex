defmodule Zaq.TestSupport.LinkedDeviceFailingListener do
  @moduledoc false
  def start_link(_opts), do: {:error, :decoder_failed}
end
