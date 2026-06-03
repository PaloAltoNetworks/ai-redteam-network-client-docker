# PANW AI Red Teaming — Docker Client

One-command Docker Compose install. No Kubernetes, no Helm. Runs on any server with Docker (EC2, VM, bare metal).

![Demo](demo.svg)

## Install

```bash
curl -fLO https://github.com/PaloAltoNetworks/ai-redteam-network-client-docker/releases/latest/download/setup-panw-network-client.sh
chmod +x setup-panw-network-client.sh
./setup-panw-network-client.sh
```

Prompts for **region**, **Client ID**, **Client Secret**. Everything else auto-discovered (TSG ID, registry credentials, image, channel).

Verify: `./setup-panw-network-client.sh --validate` — expect `Connected to the server`.

Releases ship with a Sigstore build-provenance attestation, and cloning from source is covered in the [Reference](docs/reference.md).

## Docs

- **[Reference](docs/reference.md)** — CLI modes, tunables, security, operations, K8s migration
- **Troubleshooting** — run `./setup-panw-network-client.sh --diagnose`
