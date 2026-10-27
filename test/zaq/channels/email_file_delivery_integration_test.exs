defmodule Zaq.Channels.EmailFileDeliveryIntegrationTest do
  @moduledoc "Real Disk -> authorized Outgoing -> SMTP acceptance and raw MIME readback journeys."
  use Zaq.DataCase, async: true

  alias Zaq.TestSupport.ChannelFileDelivery

  @moduletag :integration
  @moduletag timeout: 180_000

  test "only the selected signed Disk Record reaches the actual SMTP recipient" do
    ChannelFileDelivery.run!([:email])
  end

  test "an empty attachment collection produces an actual message without MIME attachments" do
    ChannelFileDelivery.run!([:email], files: false)
  end

  test "two SMTP journeys overlap without crossed files, recipients or cleanup" do
    ChannelFileDelivery.run!([:email, :email])
  end
end
