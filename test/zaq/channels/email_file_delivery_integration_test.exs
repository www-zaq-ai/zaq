defmodule Zaq.Channels.EmailFileDeliveryIntegrationTest do
  @moduledoc "Authorized Disk -> Outgoing -> real SMTP composition -> raw MIME stub capture."
  use Zaq.DataCase, async: true

  alias Zaq.TestSupport.ChannelFileDelivery

  @moduletag timeout: 180_000

  test "only the selected signed Disk Record reaches the captured SMTP envelope" do
    ChannelFileDelivery.run!([:email])
  end

  test "an empty attachment collection produces an SMTP message without MIME attachments" do
    ChannelFileDelivery.run!([:email], files: false)
  end

  test "two SMTP journeys overlap without crossed files, recipients or cleanup" do
    ChannelFileDelivery.run!([:email, :email])
  end
end
