# Connect Microsoft Teams

This guide connects ZAQ to Microsoft Teams with a single-tenant Azure Bot. For how
the channel behaves after setup, see [Microsoft Teams in the Channels guide](../services/channels.md#microsoft-teams).

## Before you start

You need:

- Permission to create an Azure Bot and an app registration in your Microsoft Entra tenant.
- Permission to upload a custom app in Teams.
- A public HTTPS address for ZAQ, because Microsoft must reach it. Set it in
  **System Configuration > Global** as the global base URL. ZAQ won't save a Teams
  connector without it.

Multi-tenant bots aren't supported.

## 1. Create the Azure Bot

1. In the Azure portal, create an **Azure Bot** resource.
2. Under **Type of App**, choose **Single Tenant**, and let Azure create a new app registration.
3. Open the bot's **Configuration** page and copy the **Microsoft App ID** and **App Tenant ID**.
4. Select **Manage Password**, create a new client secret, and copy its **Value**. Azure
   shows the value only once.
5. Under **Channels**, add **Microsoft Teams**.

## 2. Add the connector in ZAQ

1. In the Back Office, open **Channels > Microsoft Teams** and select **Add Config**.
2. Enter a name, the App ID, the Tenant ID and the Client Secret, then save.
3. Open the connector again and copy the **Messaging endpoint**. It looks like this:

   ```text
   https://zaq.example.com/channels/webhook/conversation/teams/<connector id>
   ```

4. Select **Test connection**. This requests a token from Microsoft to check the App ID,
   Tenant ID and Client Secret. It doesn't send a message.

## 3. Point the bot at ZAQ

In the Azure Bot's **Configuration** page, paste the address into **Messaging endpoint**
and save.

## 4. Install the bot in Teams

Create a Teams app package whose manifest uses your App ID as `bots[].botId`. Include the
scopes you want the bot to work in:

```json
"bots": [
  {
    "botId": "<App ID>",
    "scopes": ["personal", "groupChat", "team"],
    "supportsFiles": true
  }
]
```

`supportsFiles` is needed for files sent in personal chats.

Upload the package in Teams, then install the app in a personal chat, group chat or team.
See Microsoft's guide to
[uploading a custom app](https://learn.microsoft.com/en-us/microsoftteams/platform/concepts/deploy-and-publish/apps-upload).

## 5. Check that it works

- Send the bot a message in a personal chat. It should answer in that chat.
- In a channel or group chat, @mention the bot. It should answer in the same thread or chat.

## Troubleshooting

| What you see | What to check |
| --- | --- |
| Test connection fails | The App ID, Tenant ID and Client Secret, and that the secret hasn't expired. |
| No answer in a personal chat | The messaging endpoint in Azure, and that the connector is enabled. |
| Microsoft reports 401 from the endpoint | The App ID in ZAQ must be the same as in Azure. |
| No answer in a channel or group chat | The message must @mention the bot. |
