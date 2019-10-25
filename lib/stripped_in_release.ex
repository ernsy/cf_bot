defmodule StrippedInRelease do
  defmacro fun(do: block) do
    if Mix.env == :test || :dev do
      block
    end
  end
end

