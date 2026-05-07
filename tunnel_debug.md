# SSH Tunnel Debug Reference

> **Use `bash start_tunnel.sh` for day-to-day access.** It resolves all IPs and endpoints dynamically from `terraform output`.
> The commands below use point-in-time IPs (`52.66.196.182`, `10.0.10.125`) that will be stale after any re-apply — treat them as examples, not copy-paste commands.

## Architecture

```
kubectl (laptop)
    ↓
localhost:9443
    ↓  SSH tunnel
EC2 jumphost (public IP)
    ↓
EKS API server (private IP, port 443)
```

---

## Option 1 — One-liner (foreground)

```bash
ssh -fNT \
  -o ExitOnForwardFailure=yes \
  -o ServerAliveInterval=60 \
  -o ServerAliveCountMax=3 \
  -i ~/.ssh/csa-gg-ap-south-1-keypair.pem \
  -L 9443:<eks-private-ip>:443 \
  ec2-user@<jumphost-public-ip>
```

| Flag | Purpose |
|------|---------|
| `-f` | Fork to background after authentication succeeds |
| `-N` | No remote command — port-forward only |
| `-T` | No pseudo-terminal allocation |
| `-L 9443:<host>:443` | Forward `localhost:9443` to the EKS API via the jumphost |
| `ServerAliveInterval=60` | Send keepalive every 60 s to prevent NAT/firewall idle timeouts |
| `ServerAliveCountMax=3` | Drop connection after 3 missed keepalives (~3 min silence) |
| `ExitOnForwardFailure=yes` | Fail fast if the port-forward cannot be established |

---

## Option 2 — autossh (recommended for long-running use)

```bash
brew install autossh   # once
```

```bash
autossh -fNT \
  -M 0 \
  -o ExitOnForwardFailure=yes \
  -o ServerAliveInterval=30 \
  -o ServerAliveCountMax=3 \
  -i ~/.ssh/csa-gg-ap-south-1-keypair.pem \
  -L 9443:<eks-private-ip>:443 \
  ec2-user@<jumphost-public-ip>
```

`-M 0` disables autossh's own monitoring port and delegates keepalive to the SSH `ServerAlive` options above.

**Why autossh over plain ssh:**
- Automatically reconnects if the tunnel drops (network blip, laptop sleep, NAT timeout)
- Transparent to kubectl — local port stays bound

---

## Verify the tunnel is up

```bash
# Check the port is bound
lsof -i :9443

# Smoke-test the EKS API endpoint (TLS errors are expected — just confirms connectivity)
curl -vk https://localhost:9443

# Then confirm kubectl works
kubectl get nodes
```

---

## Tunnel management

```bash
# Kill the tunnel
pkill -f "9443:"

# Check if it is running
ps aux | grep ssh

# Restart cleanly
pkill -f "9443:"
bash start_tunnel.sh
```

---

## TLS configuration (required)

Tunnelling via IP causes a TLS hostname mismatch. Set `insecure-skip-tls-verify` on the cluster entry:

```bash
CLUSTER_ARN=$(terraform output -raw eks_cluster_arn)
kubectl config set-cluster "$CLUSTER_ARN" \
  --server=https://localhost:9443 \
  --insecure-skip-tls-verify=true
```

> This is already documented in the README Step 2 flow. Skip if you ran those steps.

---

## Optional: dedicated tunnel context

Avoids editing the default cluster entry and makes switching explicit:

```bash
CLUSTER_ARN=$(terraform output -raw eks_cluster_arn)
kubectl config set-context csa-gg-eks-tunnel \
  --cluster="$CLUSTER_ARN" \
  --user="$CLUSTER_ARN"

kubectl config use-context csa-gg-eks-tunnel
```

Switch back to jumphost (direct) access:

```bash
kubectl config use-context <original-context>
```
