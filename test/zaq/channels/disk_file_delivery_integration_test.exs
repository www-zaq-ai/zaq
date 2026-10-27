defmodule Zaq.Channels.DiskFileDeliveryIntegrationTest do
  @moduledoc "Real Disk -> authorized Outgoing -> Mattermost recipient download journeys."
  use Zaq.DataCase, async: true

  alias Zaq.TestSupport.ChannelFileDelivery

  @moduletag :integration
  @moduletag timeout: 180_000

  test "only the selected signed Disk Record reaches the actual recipient's final thread post" do
    ChannelFileDelivery.run!([:mattermost])
  end

  test "an empty attachment collection produces an actual text-only post" do
    ChannelFileDelivery.run!([:mattermost], files: false)
  end

  test "two Mattermost journeys overlap without crossed files, recipients or cleanup" do
    ChannelFileDelivery.run!([:mattermost, :mattermost])
  end

  test "Mattermost and SMTP journeys overlap with independent resources and receipts" do
    ChannelFileDelivery.run!([:mattermost, :email])
  end
end
