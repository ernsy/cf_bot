defmodule CfBot.MixProject do
  use Mix.Project

  def project do
    [
      app: :cf_bot,
      version: "0.1.0",
      elixir: "~> 1.9",
      start_permanent: Mix.env() == :prod,
      deps: deps()
    ]
  end

  # Run "mix help compile.app" to learn about applications.
  def application do
    [
      extra_applications: [:logger],
      mod: {CfBot.Application, []},
      env: [
        example: "value"
      ]
    ]
  end

  # Run "mix help deps" to learn about dependencies.
  defp deps do
    [
      # {:dep_from_hexpm, "~> 0.3.0"},
      # {:dep_from_git, git: "https://github.com/elixir-lang/my_dep.git", tag: "0.1.0"},
      # {:sibling_app_in_umbrella, in_umbrella: true}
      {:gen_state_machine, "~> 2.0"},
      {:jason, "~> 1.1"},
      {:httpoison, "~> 1.6"},
      {:logger_file_backend, "~> 0.0.11"},
      {:websockex, "~> 0.4.2"}
    ]
  end
end
