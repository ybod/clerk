defmodule ClerkTest do
  use ExUnit.Case
  doctest Clerk

  test "greets the world" do
    assert Clerk.hello() == :world
  end
end
