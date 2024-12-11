defmodule AstarteVernemq.MixProject do
  use Mix.Project

  def project do
    [
      app: :astarte_vmq_plugin,
      version: "0.1.0",
      elixir: "~> 1.15",
      start_permanent: Mix.env() == :prod,
      deps: deps()
    ]
  end

  # Run "mix help compile.app" to learn about applications.
  def application do
    [
      extra_applications: [:logger],
      mod: {Astarte.VMQ.Plugin.Application, []},
      env: [
        vmq_plugin_hooks: [
          {:auth_on_publish, Astarte.VMQ.Plugin, :auth_on_publish, 6, []},
          {:auth_on_register, Astarte.VMQ.Plugin, :auth_on_register, 5, []},
          {:auth_on_subscribe, Astarte.VMQ.Plugin, :auth_on_subscribe, 3, []},
          {:on_client_offline, Astarte.VMQ.Plugin, :on_client_offline, 1, []},
          {:on_client_gone, Astarte.VMQ.Plugin, :on_client_gone, 1, []},
          {:on_publish, Astarte.VMQ.Plugin, :on_publish, 6, []},
          {:on_register, Astarte.VMQ.Plugin, :on_register, 3, []}
        ]
      ]
    ]
  end

  # Run "mix help deps" to learn about dependencies.
  defp deps do
    [
      {:amqp, "~> 3.3"},
      {:astarte_rpc, github: "astarte-platform/astarte_rpc"},
      {:astarte_core, github: "astarte-platform/astarte_core"},
      {:vernemq_dev, github: "vernemq/vernemq_dev"},
      {:excoveralls, "~> 0.15", only: :test},
      {:mississippi, github: "secomind/mississippi"},
      {:dialyxir, "~> 1.4", only: [:dev, :ci], runtime: false},
      # {:pretty_log, github: "annopaolo/pretty_log", ref: "add-date", override: true},
      {:xandra, "~> 0.14"}
    ]
  end
end
