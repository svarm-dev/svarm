defmodule Svarm.IdentityTest do
  use ExUnit.Case, async: true

  alias Svarm.Identity

  test "slugify agent names for GitHub App slugs" do
    assert Identity.slugify("Reece") == "reece-svarm"
    assert Identity.slugify("Bug Hunter") == "bug-hunter-svarm"
    assert Identity.slugify("José") == "jose-svarm"
    assert Identity.slugify("  ") == "agent-svarm"
    assert Identity.slugify(nil) == "agent-svarm"
  end
end
