defmodule PictureRail.Setup.FieldTest do
  use ExUnit.Case, async: true

  alias PictureRail.Setup.Field

  @fields [
    %Field{key: "url", label: "URL", type: :url, required?: true},
    %Field{key: "name", label: "Name", type: :text},
    %Field{key: "key", label: "Key", type: :secret, required?: true},
    %Field{key: "on", label: "On", type: :toggle, default: true},
    %Field{key: "count", label: "Count", type: :integer, default: 5, min: 1, max: 10},
    %Field{key: "pause_ms", label: "Pause", type: :seconds, default: 0, min: 0},
    %Field{key: "ids", label: "Ids", type: {:choices, :multi}, default: []}
  ]

  test "valid values pass, URLs lose a trailing slash, defaults fill the rest" do
    assert Field.validate(@fields, "s", %{"url" => "https://x.example/", "key" => "k"}) ==
             {:ok,
              %{
                "url" => "https://x.example",
                "key" => "k",
                "on" => true,
                "count" => 5,
                "pause_ms" => 0,
                "ids" => []
              }}
  end

  test "given values of every type are kept" do
    section = %{
      "url" => "http://x",
      "name" => "frame",
      "key" => "k",
      "on" => false,
      "count" => 10,
      "pause_ms" => 2_500,
      "ids" => ["a", "b"]
    }

    assert Field.validate(@fields, "s", section) == {:ok, section}
  end

  test "undeclared keys are dropped" do
    assert {:ok, values} =
             Field.validate(@fields, "s", %{"url" => "http://x", "key" => "k", "x" => 1})

    refute Map.has_key?(values, "x")
  end

  test "every error is reported, in field order, prefixed with the section" do
    section = %{
      "url" => "x.example",
      "name" => "",
      "on" => "yes",
      "count" => 0,
      "pause_ms" => -1,
      "ids" => "a"
    }

    assert Field.validate(@fields, "s", section) ==
             {:error,
              [
                "s.url must start with http:// or https://",
                "s.name must be a non-empty string",
                "s.key is required",
                "s.on must be true or false",
                "s.count must be a positive integer",
                "s.pause_ms must be a non-negative integer",
                "s.ids must be a list of strings"
              ]}
  end

  test "integers above the maximum, non-integers and other minimums" do
    count = fn value ->
      Field.validate(@fields, "s", %{"url" => "http://x", "key" => "k", "count" => value})
    end

    assert count.(11) == {:error, ["s.count must be at most 10"]}
    assert count.(1.5) == {:error, ["s.count must be a positive integer"]}

    field = %Field{key: "n", label: "N", type: :integer, min: 3}

    assert Field.validate([field], "s", %{"n" => 2}) ==
             {:error, ["s.n must be an integer of at least 3"]}

    assert Field.validate([field], "s", %{"n" => ["a", 1]}) ==
             {:error, ["s.n must be an integer of at least 3"]}

    assert Field.validate([%Field{key: "n", label: "N", type: :integer}], "s", %{"n" => "1"}) ==
             {:error, ["s.n must be an integer"]}
  end

  test "a list with something other than strings is rejected" do
    assert Field.validate(@fields, "s", %{"url" => "http://x", "key" => "k", "ids" => ["a", 1]}) ==
             {:error, ["s.ids must be a list of strings"]}
  end

  test "the same server: scheme, host and port, and the certificate check left on" do
    fields = [
      %Field{key: "url", label: "URL", type: :url},
      %Field{key: "verify", label: "Verify", type: :toggle, default: true, secures?: true},
      %Field{key: "on", label: "On", type: :toggle, default: true}
    ]

    old = %{"url" => "https://ha.local:8123"}
    assert Field.same_server?(fields, old, %{"url" => "https://HA.local:8123/api", "on" => false})
    assert Field.same_server?(fields, old, Map.put(old, "verify", true))
    refute Field.same_server?(fields, old, %{"url" => "http://ha.local:8123"})
    refute Field.same_server?(fields, old, %{"url" => "https://ha.local:8124"})
    refute Field.same_server?(fields, old, %{"url" => "https://evil.local:8123"})
    refute Field.same_server?(fields, old, %{"url" => nil})
    refute Field.same_server?(fields, old, Map.put(old, "verify", false))
    # already off: leaving it off isn't a change
    off = Map.put(old, "verify", false)
    assert Field.same_server?(fields, off, off)
  end

  test "secret keys, and the public copy that says whether each is set" do
    assert Field.secret_keys(@fields) == ["key"]

    assert Field.public(@fields, %{"url" => "http://x", "key" => "hunter2"}) ==
             %{"url" => "http://x", "key_set?" => true}

    assert Field.public(@fields, %{"url" => "http://x"}) == %{
             "url" => "http://x",
             "key_set?" => false
           }
  end
end
