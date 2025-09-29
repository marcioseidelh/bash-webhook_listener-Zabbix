# GCP Webhook to Zabbix on Rocky Linux 8

This guide describes how to set up a simple **Bash + ncat webhook
listener** to receive **Google Cloud Monitoring alerts** and forward
them into **Zabbix trapper items**.

------------------------------------------------------------------------

## 🔧 Prerequisites

-   Rocky Linux 8 server with Zabbix agent/sender installed
-   Packages required:

``` bash
dnf -y install nmap-ncat jq
```

------------------------------------------------------------------------

## 📂 Directory and Logging Setup

``` bash
mkdir -p /var/log/webhook
touch /var/log/webhook/webhook-listener.log
ll /var/log/webhook/
```

------------------------------------------------------------------------

## 📜 Webhook Handler Script

Create the script:

``` bash
vi /opt/zabbix/scripts/webhook-gcp-zabbix/gcp-webhook-handler.sh
```

Make it executable:

``` bash
chmod 744 /opt/zabbix/scripts/gcp-webhook-handler.sh
```

This script: - Reads the HTTP request (headers + body) - Parses JSON
payload from GCP Monitoring (using `jq` if available) - Normalizes and
extracts fields: severity, policy, condition, documentation, state -
Builds a single line message in the format:

    <severity> | <policy> | <documentation> | dim=<condition_slug> | state=<open|closed>

-   Sends the message into Zabbix via `zabbix_sender`
-   Logs debug info into `/var/log/webhook/webhook-listener.log`
-   Returns HTTP 200 to prevent GCP retries

------------------------------------------------------------------------

## ⚙️ Systemd Service

Create systemd service:

``` bash
vi /etc/systemd/system/gcp-webhook.service
```

Example unit:

    [Unit]
    Description=GCP Monitoring Webhook -> Zabbix
    After=network-online.target
    Wants=network-online.target

    [Service]
    ExecStart=/usr/bin/ncat -lkv -p 10060 -c /opt/zabbix/scripts/webhook-gcp-zabbix/gcp-webhook-handler.sh
    Restart=always
    RestartSec=1
    User=root
    Group=root
    Environment=LANG=C
    StandardOutput=journal
    StandardError=journal

    [Install]
    WantedBy=multi-user.target

Reload and enable:

``` bash
systemctl daemon-reload
systemctl enable --now gcp-webhook.service
systemctl status gcp-webhook.service --no-pager
```

Check listener:

``` bash
netstat -nap | grep 10060
```

------------------------------------------------------------------------

## 🧪 Local Test (before configuring GCP)

``` bash
curl -s -D- -X POST http://127.0.0.1:10060/   -H 'Content-Type: application/json'   --data '{"version":"test","incident":{"policy_name":"My Policy","severity":"Critical","documentation":{"content":"Test Doc"}}}'
```

Check logs:

``` bash
tail -f /var/log/webhook/webhook-listener.log
```

------------------------------------------------------------------------

## 📡 Zabbix Configuration (v7)

### Item

-   **Name:** Webhook Alert
-   **Type:** Zabbix trapper
-   **Key:** webhook.alert
-   **Type of information:** Text

### Triggers Examples

**VPN Outgoing Packets Dropped**
- Problem expression:
```{=html}
find(/hostname.domain/webhook.alert,#1,"regexp","dim=outgoing_packets_dropped\s*\|\s*state=open")=1
```

-   Recovery expression:

```{=html}
find(/hostname.domain/webhook.alert,#1,"regexp","dim=outgoing_packets_dropped\s*\|\s*state=closed")=1
```

**VPN Incoming Packets Dropped**
- Problem expression:
```{=html}
find(/hostname.domain/webhook.alert,#1,"regexp","dim=vpn_incoming_packets_dropped\s*\|\s*state=open")=1
```

-   Recovery expression:
```{=html}
find(/hostname.domain/webhook.alert,#1,"regexp","dim=vpn_incoming_packets_dropped\s*\|\s*state=closed")=1
```

------------------------------------------------------------------------

## ✅ Summary

-   GCP Monitoring alerts → delivered via webhook → parsed by Bash
    script → forwarded to Zabbix trapper item\
-   Simple, lightweight, no external dependencies beyond `ncat` and
    `jq`\
-   Tested with **Zabbix 7.0 LTS**
