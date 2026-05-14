# kotoba-press-deployer

Central deployment hub for the Kotoba Press application. Orchestrates deployment of all three services to **Azure Container Apps** and provides a one-command local development environment via Docker Compose.

## Repository Map

| Repo | Image | Ingress |
|------|-------|---------|
| `Tranduy1dol/kotoba-press` | `ghcr.io/tranduy1dol/kotoba-ui` | Public (port 80) |
| `Tranduy1dol/kotoba-press-core` | `ghcr.io/tranduy1dol/kotoba-core` | Public (port 8080) |
| `Tranduy1dol/search` | `ghcr.io/tranduy1dol/kotoba-search-engine` | Internal only (port 50051) |

Each source repo publishes a Docker image to GHCR on every push to `main`, then triggers this deployer via `repository_dispatch`. The deployer's workflow updates the corresponding Azure Container App.

---

## Local Development

No need to clone any source repo. Just pull the pre-built images and run.

### Prerequisites

- Docker and Docker Compose installed
- GHCR packages on `Tranduy1dol` set to **Public**

### Run the stack

```bash
# Copy and fill in your secrets
cp .env.example .env

# Pull latest images and start
docker compose pull
docker compose up
```

| Service | URL |
|---------|-----|
| Frontend | http://localhost:3000 |
| Backend API | http://localhost:8080 |
| Search gRPC | localhost:50051 (internal) |

### `.env` file (never commit this)

```bash
# MongoDB Atlas
MONGO_URI=mongodb+srv://<user>:<password>@<cluster>.mongodb.net/kotoba?retryWrites=true&w=majority

# Redis Cloud
REDIS_ADDR=<host>:<port>
REDIS_PASSWORD=<password>

# App
JWT_SECRET=<secret>
```

---

## One-Time Azure Setup

### Prerequisites

Azure CLI has a known bug on Arch Linux with Python 3.14. Use Docker to run it instead:

```bash
docker run -it mcr.microsoft.com/azure-cli
az login
```

### 1. Get your Subscription ID

```bash
az account show --query id -o tsv
```

### 2. Create the Resource Group

> **Note:** Azure Student accounts restrict certain regions. Use `japaneast` or `eastus` — `southeastasia` may be blocked.

```bash
az group create --name kotoba-press-rg --location japaneast
```

### 3. Register required providers (once per subscription)

```bash
az provider register -n Microsoft.App --wait
az provider register -n Microsoft.OperationalInsights --wait
```

### 4. Create the Container Apps Environment

```bash
az containerapp env create \
  --name kotoba-env \
  --resource-group kotoba-press-rg \
  --location japaneast
```

### 5. Create the Container Apps (empty, first time only)

```bash
# Search Service — internal only, always on
az containerapp create \
  --name search-grpc \
  --resource-group kotoba-press-rg \
  --environment kotoba-env \
  --image ghcr.io/tranduy1dol/kotoba-search-engine:latest \
  --target-port 50051 \
  --transport http2 \
  --ingress internal \
  --cpu 0.5 --memory 1Gi \
  --min-replicas 1

# Go Backend — public API
az containerapp create \
  --name kotoba-core \
  --resource-group kotoba-press-rg \
  --environment kotoba-env \
  --image ghcr.io/tranduy1dol/kotoba-core:latest \
  --target-port 8080 \
  --ingress external \
  --cpu 0.5 --memory 1Gi

# Vite Frontend — public UI
az containerapp create \
  --name kotoba-ui \
  --resource-group kotoba-press-rg \
  --environment kotoba-env \
  --image ghcr.io/tranduy1dol/kotoba-ui:latest \
  --target-port 80 \
  --ingress external \
  --cpu 0.5 --memory 1Gi
```

### 6. Store app secrets in Azure (not in GitHub)

```bash
az containerapp secret set \
  --name kotoba-core \
  --resource-group kotoba-press-rg \
  --secrets \
    mongo-uri="mongodb+srv://user:pass@cluster.mongodb.net/kotoba" \
    redis-addr="your-redis-host:port" \
    redis-password="your-redis-password"
```

### 7. Get your live URLs

```bash
# Frontend
az containerapp show \
  --name kotoba-ui \
  --resource-group kotoba-press-rg \
  --query properties.configuration.ingress.fqdn \
  --output tsv

# Backend API
az containerapp show \
  --name kotoba-core \
  --resource-group kotoba-press-rg \
  --query properties.configuration.ingress.fqdn \
  --output tsv
```

---

## GitHub Actions Setup (One-Time)

### Secrets needed on this repo

| Secret | How to get it |
|--------|--------------|
| `AZURE_CREDENTIALS` | See step below |

### Create the Azure service principal

```bash
az ad sp create-for-rbac \
  --name "github-actions-deployer" \
  --role contributor \
  --scopes /subscriptions/<YOUR_SUBSCRIPTION_ID>/resourceGroups/kotoba-press-rg \
  --json-auth
```

Copy the entire JSON output → GitHub → this repo → **Settings → Secrets → Actions → New secret**
- Name: `AZURE_CREDENTIALS`
- Value: paste the JSON

### Secrets needed on each source repo

Each source repo needs a PAT so it can trigger this deployer.

1. Go to https://github.com/settings/tokens → **Generate new token (classic)**
2. Name: `deploy-pat`, Scope: `repo` (full)
3. Add as `DEPLOY_PAT` secret to all 3 source repos:
   - `Tranduy1dol/search`
   - `Tranduy1dol/kotoba-press-core`
   - `Tranduy1dol/kotoba-press`

---

## How Deployments Work

### Automatic (push to main on any source repo)

```
Push to search/kotoba-press-core/kotoba-press (main)
  → Source repo CI: build + test + publish image to GHCR
  → Source repo CI: sends repository_dispatch to this repo
  → This repo: .github/workflows/deploy.yml runs
  → az containerapp update → new image goes live
```

### Manual (on-demand from GitHub UI)

Go to this repo → **Actions** → **Deploy to Azure** → **Run workflow**
- Select the service (`search-grpc`, `kotoba-core`, `kotoba-ui`)
- Optionally specify an image tag (defaults to `latest`)

### Rollback to a previous version

Every image is tagged with the git SHA of the commit that built it:

```bash
az containerapp update \
  --name kotoba-core \
  --resource-group kotoba-press-rg \
  --image ghcr.io/tranduy1dol/kotoba-core:<previous-sha>
```

---

## Cost Estimate (Azure Student Credits)

| Resource | Monthly |
|----------|---------|
| Container Registry (GHCR) | Free |
| Container Apps (kotoba-ui, scale to zero) | ~$0–3 |
| Container Apps (kotoba-core, scale to zero) | ~$0–5 |
| Container Apps (search-grpc, min 1 replica) | ~$5–10 |
| Log Analytics workspace | ~$0 (free tier) |
| **Total** | **~$5–18/month** |

With $100 Azure credits: **~5–10 months** of runway.
