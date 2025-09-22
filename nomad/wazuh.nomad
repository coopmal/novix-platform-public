job "wazuh" {
  datacenters = ["dc1"]
  type        = "service"

  group "wazuh-group" {
    count = 1

    # === Vault integration for TLS secrets ===
    vault {
      policies    = ["wazuh"]
      change_mode = "restart"
    }

    network {
      mode = "bridge"

      port "manager"   { static = 1514 to = 1514 protocol = "udp" }
      port "api"       { static = 55000 }
      port "dashboard" { static = 5601 }
      port "cluster"   { static = 1515 }
      port "auth"      { static = 1516 }
      port "indexer"   { static = 9200 }
    }

    # === Services registration ===
    service { name="wazuh-manager" port="manager" check { type="udp" interval="10s" timeout="2s" } }
    service { name="wazuh-api"     port="api"     check { type="tcp" interval="10s" timeout="2s" } }
    service { name="wazuh-dashboard" port="dashboard" check { type="http" path="/" interval="10s" timeout="2s" } }
    service { name="wazuh-cluster" port="cluster" check { type="tcp" interval="10s" timeout="2s" } }
    service { name="wazuh-auth"    port="auth" check { type="tcp" interval="10s" timeout="2s" } }
    service { name="wazuh-indexer" port="indexer" check { type="tcp" interval="10s" timeout="2s" } }

    # === Persistent Volumes ===
    volume "wazuh-data-manager"     { type="host" read_only=false source="./volumes/wazuh/manager/data" }
    volume "wazuh-logs-manager"     { type="host" read_only=false source="./volumes/wazuh/manager/logs" }
    volume "wazuh-config-manager"   { type="host" read_only=true  source="./config/wazuh/manager" }

    volume "wazuh-data-indexer"     { type="host" read_only=false source="./volumes/wazuh/indexer/data" }
    volume "wazuh-logs-indexer"     { type="host" read_only=false source="./volumes/wazuh/indexer/logs" }
    volume "wazuh-config-indexer"   { type="host" read_only=true  source="./config/wazuh/indexer" }

    volume "wazuh-data-dashboard"   { type="host" read_only=false source="./volumes/wazuh/dashboard/data" }
    volume "wazuh-logs-dashboard"   { type="host" read_only=false source="./volumes/wazuh/dashboard/logs" }
    volume "wazuh-config-dashboard" { type="host" read_only=true  source="./config/wazuh/dashboard" }

    volume "wazuh-certs"            { type="host" read_only=true  source="./certs/wazuh" }

    # === Wazuh Manager ===
    task "manager" {
      driver = "docker"
      depends_on = ["wait-for-certs"]

      config {
        image = "wazuh/wazuh-manager:4.12.0"
        dns_config { 
          nameservers=["consul.service.consul:8600"] 
          searches=["service.consul"] 
        }
        ports = ["manager","cluster","auth","api"]
        volumes = [
          "wazuh-data-manager:/var/ossec/data",
          "wazuh-logs-manager:/var/ossec/logs",
          "wazuh-config-manager:/var/ossec/etc",
          "wazuh-certs:/etc/ssl/certs"
        ]
      }

      volume_mount { volume="wazuh-data-manager" destination="/var/ossec/data" read_only=false }
      volume_mount { volume="wazuh-logs-manager" destination="/var/ossec/logs" read_only=false }
      volume_mount { volume="wazuh-config-manager" destination="/var/ossec/etc" read_only=false }
      volume_mount { volume="wazuh-certs" destination="/etc/ssl/certs" read_only=true }

      # === Vault templates for Traefik-managed certs ===
      template {
        data        = "{{ with secret "secret/wazuh/fullchain" }}{{ .Data.data.fullchain }}{{ end }}"
        destination = "/etc/ssl/certs/wazuh.manager.pem"
        change_mode = "restart"
      }
      template {
        data        = "{{ with secret "secret/wazuh/privkey" }}{{ .Data.data.privkey }}{{ end }}"
        destination = "/etc/ssl/certs/wazuh.manager-key.pem"
        change_mode = "restart"
      }
      template {
        data        = "{{ with secret "secret/wazuh/ca" }}{{ .Data.data.cert }}{{ end }}"
        destination = "/etc/ssl/certs/root-ca-manager.pem"
        change_mode = "restart"
      }

      env {
        INDEXER_URL                    = "http://wazuh-indexer.service.consul:9200"
        INDEXER_USERNAME               = "admin"
        INDEXER_PASSWORD               = "SecretPassword"
        FILEBEAT_SSL_VERIFICATION_MODE = "full"
        SSL_CERTIFICATE_AUTHORITIES    = "/etc/ssl/certs/root-ca-manager.pem"
        SSL_CERTIFICATE                = "/etc/ssl/certs/wazuh.manager.pem"
        SSL_KEY                        = "/etc/ssl/certs/wazuh.manager-key.pem"
        API_USERNAME                   = "wazuh-wui"
        API_PASSWORD                   = "MyS3cr37P450r.*-"
        CLUSTER_NAME                   = "wazuh-cluster"
      }

      restart { attempts=3 interval="5m" delay="15s" mode="delay" }
    }

    # === Wazuh Indexer ===
    task "indexer" {
      driver = "docker"

      config {
        image = "wazuh/wazuh-indexer:4.12.0"
        dns_config { 
          nameservers=["consul.service.consul:8600"]
          searches=["service.consul"]
        }
        ports = ["indexer"]
        volumes = [
          "wazuh-data-indexer:/var/lib/wazuh-indexer",
          "wazuh-logs-indexer:/var/log/wazuh-indexer",
          "wazuh-config-indexer/opensearch.yml:/usr/share/wazuh-indexer/opensearch.yml",
          "wazuh-certs:/usr/share/wazuh-indexer/certs"
        ]
      }

      volume_mount { volume="wazuh-data-indexer" destination="/var/lib/wazuh-indexer" read_only=false }
      volume_mount { volume="wazuh-logs-indexer" destination="/var/log/wazuh-indexer" read_only=false }
      volume_mount { volume="wazuh-config-indexer" destination="/usr/share/wazuh-indexer/opensearch.yml" read_only=true }
      volume_mount { volume="wazuh-certs" destination="/usr/share/wazuh-indexer/certs" read_only=true }

      env { OPENSEARCH_JAVA_OPTS = "-Xms1g -Xmx1g" }
      restart { attempts=3 interval="5m" delay="15s" mode="delay" }
    }

    # === Wazuh Dashboard ===
    task "dashboard" {
      driver = "docker"

      config {
        image = "wazuh/wazuh-dashboard:4.12.0"
        dns_config { 
          nameservers=["consul.service.consul:8600"] 
          searches=["service.consul"] 
        }
        ports = ["dashboard"]
        volumes = ["wazuh-data-dashboard:/usr/share/wazuh-dashboard/data"]
      }

      volume_mount { volume="wazuh-data-dashboard" destination="/usr/share/wazuh-dashboard/data" read_only=false }

      env {
        API_HOST           = "http://wazuh-api.service.consul:55000"
        API_USERNAME       = "wazuh-wui"
        API_PASSWORD       = "MyS3cr37P450r.*-"
        INDEXER_USERNAME   = "admin"
        INDEXER_PASSWORD   = "SecretPassword"
        WAZUH_API_URL      = "http://wazuh-manager.service.consul:55000"
        DASHBOARD_USERNAME = "kibanaserver"
        DASHBOARD_PASSWORD = "kibanaserver"
      }

      restart { attempts=3 interval="5m" delay="15s" mode="delay" }

      meta {
        "traefik.enable"                             = "true"
        "traefik.http.routers.wazuh.rule"            = "Host(`wazuh.acetos.be`)"
        "traefik.http.routers.wazuh.entrypoints"     = "websecure"
        "traefik.http.routers.wazuh.tls.certresolver"= "letsencrypt"
        "traefik.http.routers.wazuh-http.rule"       = "Host(`wazuh.acetos.be`)"
        "traefik.http.routers.wazuh-http.entrypoints"= "web"
        "traefik.http.routers.wazuh-http.middlewares"= "redirect-to-https"
        "traefik.http.services.wazuh.loadbalancer.server.port" = "5601"
      }
    }
  }
}
