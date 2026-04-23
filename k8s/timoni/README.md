# Homelab K3s Timoni Bundle

## Prerequisites

- `kubectl` configured for your k3s cluster
- `timoni` CLI (available in devShell)

## Deploy

```bash
# Preview changes
timoni bundle apply --dry-run -f bundle.cue

# Apply
timoni bundle apply -f bundle.cue

# Check status
timoni bundle status -f bundle.cue
```

## Included Modules

| Module         | Namespace     | Purpose                          |
|----------------|---------------|----------------------------------|
| cert-manager   | cert-manager  | TLS certificate management       |
| metrics-server | kube-system   | Resource metrics (kubectl top)   |

## Next Steps

After cert-manager is running, create a ClusterIssuer for your internal CA:

```yaml
apiVersion: cert-manager.io/v1
kind: ClusterIssuer
metadata:
  name: homelab-ca
spec:
  ca:
    secretName: homelab-ca-keypair
```
