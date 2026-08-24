import Config

sidecar_url = System.get_env("COMMONPLACE_SIDECAR_URL") || "http://storage.internal"

config :commonplace_log, Commonplace.Log.RealmNode,
  persistence: {Commonplace.Log.Persistence.CloudflareSidecar, base_url: sidecar_url}

if port = System.get_env("COMMONPLACE_REALM_HTTP_PORT") do
  config :commonplace_log, Commonplace.Log.RealmNode, http_port: String.to_integer(port)
end
