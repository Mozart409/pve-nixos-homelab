# Loki: the central log store the whole fleet ships to.
#
# Lives here rather than inline in hosts/otel/configuration.nix so the SERVER
# and the SHIPPER (modules/fluent-bit.nix) are separate, importable units. They
# are two halves of one system but have no business being coupled through a
# host file -- fluent-bit hosts need the shipper and not this, and this needs
# no shipper config at all.
#
# Imported only by the host that actually runs Loki. Everything else reaches it
# over https://loki.homelab.local (a Caddy vhost on that same host, terminating
# step-ca TLS and reverse-proxying to localhost:3100).
{...}: {
  services.loki = {
    enable = true;
    configuration = {
      auth_enabled = false;
      server = {
        http_listen_port = 3100;
        grpc_listen_port = 9096;
      };
      common = {
        path_prefix = "/var/lib/loki";
        storage.filesystem = {
          chunks_directory = "/var/lib/loki/chunks";
          rules_directory = "/var/lib/loki/rules";
        };
        replication_factor = 1;
        ring = {
          instance_addr = "127.0.0.1";
          kvstore.store = "inmemory";
        };
      };
      schema_config.configs = [
        {
          from = "2024-01-01";
          store = "tsdb";
          object_store = "filesystem";
          schema = "v13";
          index = {
            prefix = "index_";
            period = "24h";
          };
        }
      ];
      limits_config = {
        retention_period = "168h"; # 7 days
        allow_structured_metadata = true;
        volume_enabled = true;
      };
      compactor = {
        working_directory = "/var/lib/loki/compactor";
        compaction_interval = "10m";
        retention_enabled = true;
        retention_delete_delay = "2h";
        delete_request_store = "filesystem";
      };
    };
  };
}
