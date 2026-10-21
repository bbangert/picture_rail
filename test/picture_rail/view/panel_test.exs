defmodule PictureRail.View.PanelTest do
  use ExUnit.Case, async: true

  alias PictureRail.View.Panel

  defp section(name, rows, h \\ 84) do
    heading = {:heading, 0, name}
    [heading | Enum.map(1..rows//1, &{:row, h, [{name, &1}], heading})]
  end

  # heading 38, rows h; gaps: heading->row 14, row->row 12, otherwise 28
  defp height(page) do
    {sum, _} =
      Enum.reduce(page, {0, nil}, fn block, {sum, prev} ->
        h = if elem(block, 0) == :heading, do: 38, else: elem(block, 1)

        gap =
          case {prev, block} do
            {nil, _} -> 0
            {{:heading, _, _}, {:row, _, _, _}} -> 14
            {{:row, _, _, _}, {:row, _, _, _}} -> 12
            _ -> 28
          end

        {sum + gap + h, block}
      end)

    sum
  end

  test "everything on one page when it fits" do
    blocks = section("a", 2) ++ section("b", 1)
    assert Panel.paginate(blocks, 1_000) == [blocks]
  end

  test "pages never overflow, and a cut section repeats its heading" do
    pages = Panel.paginate(section("a", 10), 400)

    assert length(pages) > 1
    assert Enum.all?(pages, &(height(&1) <= 400))
    assert Enum.all?(pages, &match?([{:heading, 0, "a"} | _], &1))
    rows = pages |> List.flatten() |> Enum.filter(&match?({:row, _, _, _}, &1))
    assert length(rows) == 10
  end

  test "a heading isn't left alone at the bottom of a page" do
    # 'a' fills most of the page; 'b''s heading and first row don't fit after it
    blocks = section("a", 3) ++ section("b", 2)
    pages = Panel.paginate(blocks, 38 + 14 + 84 * 3 + 12 * 2 + 28 + 38 + 10)

    for page <- pages, do: refute(match?({:heading, _, _}, List.last(page)))
    assert [{:heading, 0, "b"} | _] = Enum.at(pages, 1)
  end

  test "a page starting at an area heading repeats its floor's heading" do
    floor = {:heading, 0, "Ground"}
    kitchen = {:subheading, 0, "Kitchen"}
    living = {:subheading, 0, "Living"}
    row = fn sub, n -> {:row, 84, [n], [floor, sub]} end

    blocks = [
      floor,
      kitchen,
      row.(kitchen, 1),
      row.(kitchen, 2),
      living,
      row.(living, 3),
      row.(living, 4)
    ]

    pages = Panel.paginate(blocks, 300)

    assert length(pages) > 1
    assert Enum.all?(pages, &match?([{:heading, 0, "Ground"} | _], &1))
  end

  describe "navigation pages" do
    # The 1366x768 unit: 486 px of sidebar, less the UP and DOWN blocks.
    @limit 486 - 2 * (56 + 6)

    defp nav_height({{:divider, _}, _}), do: 40 + 6
    defp nav_height(_item), do: 72 + 6

    defp nav(floors) do
      areas =
        Enum.flat_map(floors, fn {floor, n} ->
          [
            {:divider, floor}
            | for(i <- 1..n, do: {:view, {:area, "#{floor}#{i}"}, "#{floor} #{i}"})
          ]
        end)

      Enum.with_index([{:view, :overview, "Overview"}] ++ areas ++ [{:view, :media, "Media"}])
    end

    test "every page fits, and a floor divider never ends one" do
      for floors <- [[{"G", 2}, {"U", 3}, {"B", 4}], [{"G", 1}, {"U", 1}, {"B", 1}, {"A", 6}]] do
        pages = Panel.nav_pages(nav(floors), @limit, &nav_height/1)

        for page <- pages do
          assert page |> Enum.map(&nav_height/1) |> Enum.sum() <= @limit
          refute match?({{:divider, _}, _}, List.last(page))
        end

        assert Enum.concat(pages) == nav(floors)
      end
    end
  end

  test "no blocks is one empty page" do
    assert Panel.paginate([], 500) == [[]]
  end

  test "pagination needs only heights: a row's item functions aren't called" do
    test = self()
    item = fn n -> fn -> send(test, {:built, n}) end end
    heading = {:heading, 0, "a"}
    blocks = [heading | for(n <- 1..30, do: {:row, 84, [item.(n)], heading})]

    assert [_ | _] = Panel.paginate(blocks, 500)
    refute_received {:built, _}
  end

  test "a long list builds only the page shown" do
    ids = for n <- 1..60, do: "light.l#{n}"

    states =
      Map.new(ids, &{&1, %Hassock.EntityState{entity_id: &1, state: "on", attributes: %{}}})

    names = Map.new(Enum.with_index(ids, 1), fn {id, n} -> {{id, :full}, "Lamp #{n}"} end)
    # a name that can't be drawn, on the last page: building that pill
    # raises, so page 0 renders only if off-page pills aren't built
    names = Map.put(names, {"light.l60", :full}, {:not, :a, :name})
    slice = %{sections: [%{title: "Lights", groups: [%{title: nil, entity_ids: ids}]}]}

    ctx = %{
      size: {1920, 1080},
      portrait?: false,
      panel: %{visible?: true, view: {:summary, :light}, page: 0, nav_page: 0, depth: 1},
      ha: %{status: :connected, slice: slice, states: states, names: names, nav: []},
      setup: nil,
      settings: nil,
      photos: nil,
      network: nil,
      pairing: nil,
      sliders: %{}
    }

    tree = inspect(Panel.render(ctx), limit: :infinity, printable_limit: :infinity)
    assert tree =~ "LAMP 1\""
    refute tree =~ "LAMP 60\""
  end

  test "an entity's detail renders without anything from Home Assistant" do
    # as the viewport has it while the :ha controller is down
    ctx = %{
      size: {1920, 1080},
      portrait?: false,
      panel: %{visible?: true, view: {:entity, "light.hall"}, page: 0, nav_page: 0, depth: 1},
      ha: %{status: :unconfigured, slice: nil, states: %{}},
      setup: nil,
      settings: nil,
      photos: nil,
      network: nil,
      pairing: nil,
      sliders: %{}
    }

    assert Panel.render(ctx)
  end

  test "with nothing from Home Assistant yet, the panel says why" do
    assert Panel.waiting_message(:connecting) == "Loading"
    assert Panel.waiting_message(:connected) == "Loading"
    assert Panel.waiting_message(:disconnected) == "Can't reach Home Assistant"
    assert Panel.waiting_message({:auth_failed, "invalid"}) == "Home Assistant refused the token"
    assert Panel.waiting_message(:unconfigured) == "Home Assistant isn't set up"
  end

  test "Setup is in the navigation, also when Home Assistant has none" do
    assert Panel.nav_items(%{ha: %{status: :unconfigured}}) == [{:view, :setup, "Setup"}]

    assert Panel.nav_items(%{ha: %{nav: [{:view, :overview, "Overview"}]}}) == [
             {:view, :overview, "Overview"},
             {:view, :setup, "Setup"}
           ]

    assert Panel.setup_view?(:setup)
    assert Panel.setup_view?({:setup, :display})
    refute Panel.setup_view?(:overview)
  end
end
