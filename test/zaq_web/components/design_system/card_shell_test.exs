defmodule ZaqWeb.Components.DesignSystem.CardShellTest do
  use ZaqWeb.ConnCase, async: true
  use ExUnitProperties

  import Phoenix.Component, only: [sigil_H: 2]
  import Phoenix.LiveViewTest

  alias ZaqWeb.Components.DesignSystem.CardShell

  test "card_shell/1 renders muted surface without hover class" do
    assigns = %{}

    html =
      rendered_to_string(~H"""
      <CardShell.card_shell id="muted-card" variant={:muted} as={:div}>
        Body
      </CardShell.card_shell>
      """)

    assert html =~ "id=\"muted-card\""
    assert html =~ "Body"
    assert html =~ "zaq-card-default"
    refute html =~ "zaq-card-hover"
    refute html =~ "href="
  end

  test "card_shell/1 wraps interactive card with link and hover surface" do
    assigns = %{}

    html =
      rendered_to_string(~H"""
      <CardShell.card_shell
        id="linked-card"
        primary_link={%{destination: "/bo/channels"}}
      >
        Tile
      </CardShell.card_shell>
      """)

    assert html =~ ~s(href="/bo/channels")
    assert html =~ "Tile"
    assert html =~ "zaq-card-hover"
    assert html =~ "id=\"linked-card\""

    document = LazyHTML.from_fragment(html)
    assert Enum.count(LazyHTML.query(document, "#linked-card")) == 1
    assert Enum.count(LazyHTML.query(document, "a#linked-card")) == 1
    assert Enum.empty?(LazyHTML.query(document, "article[id]"))
  end

  test "card_shell/1 renders footer ghost button with split primary link" do
    assigns = %{}

    html =
      rendered_to_string(~H"""
      <CardShell.card_shell
        id="provider-card"
        primary_link={%{destination: "/bo/channels/retrieval/slack"}}
        footer_link={
          %{
            id: "provider-card-configure",
            label: "Configure",
            destination: "/bo/channels/retrieval/slack"
          }
        }
      >
        <:header>Slack header</:header>
        Slack
        <:footer>Slack footer</:footer>
      </CardShell.card_shell>
      """)

    assert html =~ ~s(href="/bo/channels/retrieval/slack")
    assert html =~ "id=\"provider-card-configure\""
    assert html =~ "Slack header"
    assert html =~ "Slack"
    assert html =~ "Slack footer"
    assert html =~ "Configure"
    assert html =~ "zaq-btn"
  end

  test "card_shell/1 renders secondary link below card" do
    assigns = %{}

    html =
      rendered_to_string(~H"""
      <CardShell.card_shell
        id="metric-shell"
        primary_link={%{id: "metric-link", destination: "/bo/ingestion"}}
        secondary_link={
          %{
            id: "metric-secondary",
            destination: "/bo/dashboard",
            label: "View dashboard"
          }
        }
      >
        128
      </CardShell.card_shell>
      """)

    assert html =~ "space-y-2"
    assert html =~ "128"
    assert html =~ "id=\"metric-secondary\""
    assert html =~ "View dashboard"
  end

  test "whole-card navigation keeps distinct caller IDs and collapses equal IDs" do
    distinct =
      render_card_shell(
        id: "distinct-card",
        primary_link: %{id: "distinct-link", destination: "/bo/channels"}
      )

    distinct_document = LazyHTML.from_fragment(distinct)
    assert element_ids(distinct_document) == ["distinct-link", "distinct-card"]
    assert Enum.count(LazyHTML.query(distinct_document, "a#distinct-link")) == 1
    assert Enum.count(LazyHTML.query(distinct_document, "article#distinct-card")) == 1

    equal =
      render_card_shell(
        id: "equal-card",
        primary_link: %{id: "equal-card", destination: "/bo/channels"}
      )

    equal_document = LazyHTML.from_fragment(equal)
    assert element_ids(equal_document) == ["equal-card"]
    assert Enum.count(LazyHTML.query(equal_document, "a#equal-card")) == 1
    assert Enum.empty?(LazyHTML.query(equal_document, "article[id]"))
  end

  test "split-footer navigation assigns the card ID only to the surface" do
    for primary_id <- [nil, "", "split-card"] do
      html =
        render_card_shell(
          id: "split-card",
          primary_link: %{id: primary_id, destination: "/bo/channels"},
          footer_link: footer_link("split-footer")
        )

      document = LazyHTML.from_fragment(html)
      assert element_ids(document) == ["split-card", "split-footer"]
      assert Enum.count(LazyHTML.query(document, "article#split-card")) == 1
      assert Enum.empty?(LazyHTML.query(document, "article#split-card > a[id]"))
    end

    html =
      render_card_shell(
        id: "split-card",
        primary_link: %{id: "split-primary", destination: "/bo/channels"},
        footer_link: footer_link("split-footer")
      )

    document = LazyHTML.from_fragment(html)
    assert element_ids(document) == ["split-card", "split-primary", "split-footer"]
  end

  property "card surfaces and navigation controls always have unique DOM IDs" do
    check all(
            token <- string(:alphanumeric, min_length: 1, max_length: 24),
            primary_id_mode <- member_of([:missing, :blank, :equal, :distinct]),
            split_footer? <- boolean(),
            external? <- boolean()
          ) do
      card_id = "surface-#{token}"

      primary_id =
        case primary_id_mode do
          :missing -> nil
          :blank -> ""
          :equal -> card_id
          :distinct -> "primary-#{token}"
        end

      html =
        render_card_shell(
          id: card_id,
          primary_link: %{
            id: primary_id,
            destination: "/bo/channels/#{token}",
            external: external?
          },
          footer_link: if(split_footer?, do: footer_link("footer-#{token}"), else: nil)
        )

      ids = html |> LazyHTML.from_fragment() |> element_ids()
      assert length(ids) == MapSet.size(MapSet.new(ids))
    end
  end

  defp render_card_shell(opts) do
    assigns = %{
      id: Keyword.fetch!(opts, :id),
      primary_link: Keyword.fetch!(opts, :primary_link),
      footer_link: Keyword.get(opts, :footer_link)
    }

    rendered_to_string(~H"""
    <CardShell.card_shell
      id={@id}
      primary_link={@primary_link}
      footer_link={@footer_link}
    >
      Body
    </CardShell.card_shell>
    """)
  end

  defp footer_link(id) do
    %{id: id, label: "Configure", destination: "/bo/channels"}
  end

  defp element_ids(document), do: document |> LazyHTML.query("[id]") |> LazyHTML.attribute("id")
end
