defmodule Emaki.MixProject do
  use Mix.Project

  def project do
    [
      app: :emaki,
      version: "0.1.0",
      elixir: "~> 1.18",
      start_permanent: Mix.env() == :prod,
      deps: deps(),
      description:
        "Official SDK for emaki (emaki.ai): generate Seedance 2.5 and Seedance 2.0 videos and images from Elixir with your emaki API key.",
      package: package(),
      docs: [main: "readme", extras: ["README.md"]],
      source_url: "https://github.com/hanshs474/emaki-ex",
      homepage_url: "https://emaki.ai/?utm_source=hex&utm_medium=package"
    ]
  end

  def application do
    [extra_applications: [:logger, :inets, :ssl, :public_key, :crypto]]
  end

  defp deps do
    [{:ex_doc, "~> 0.34", only: :dev, runtime: false}]
  end

  defp package do
    [
      licenses: ["MIT"],
      links: %{
        "Website" => "https://emaki.ai/?utm_source=hex&utm_medium=package",
        "Seedance 2.5" => "https://emaki.ai/seedance-2-5",
        "GitHub" => "https://github.com/hanshs474/emaki-ex"
      },
      files: ~w(lib mix.exs README.md LICENSE)
    ]
  end
end
