# Master Key Management

## Overview

The LiteLLM proxy uses a secure master key for authentication. This key is stored as a Container Apps secret and is not committed to the git repository.

## Key Storage

- **Location**: Azure Container Apps secret named `litellm-master-key`
- **Source**: Environment variable `TF_VAR_litellm_master_key` from `infra/.env` file
- **Security**: 64-character cryptographically secure random string

## How to Retrieve the Master Key

### Method 1: From Local .env File (Recommended)
```bash
cd infra
cat .env | grep TF_VAR_litellm_master_key
```

### Method 2: From Azure Container Apps (via Azure CLI)
```bash
# Note: This requires appropriate permissions on the Container App
az containerapp secret show --name litellm-proxy --resource-group AzureLIT-POC --secret-name litellm-master-key
```

### Method 3: From Azure Portal
1. Navigate to Azure Portal → Container Apps
2. Select `litellm-proxy` in resource group `AzureLIT-POC`
3. Go to "Secrets" section
4. View the `litellm-master-key` secret value

## Current Master Key
The master key value is stored securely and must not be committed to source control. Retrieve it from your local `.env` or Azure Container Apps secret as documented above.

## Usage
Use the master key in the `Authorization` header when making requests to the LiteLLM proxy:
```bash
# Replace <MASTER_KEY> with your actual secret from infra/.env or Container Apps
curl -H "Authorization: Bearer <MASTER_KEY>" \
  https://<your-container-app-host>/v1/models
```

## Key Rotation

To rotate the master key:

1. Generate a new secure key:
   ```bash
   openssl rand -base64 48 | tr -d "=+/" | cut -c1-64
   ```

2. Update the `.env` file:
   ```bash
   cd infra
   # Edit .env file with new key
   nano .env
   ```

3. Apply the changes:
   ```bash
   cd infra
   source .env
   terraform apply -auto-approve
   ```

4. Update this documentation with the new key

## Security Notes

- **Never commit** the `.env` file to git (it's in `.gitignore`)
- **Rotate the key** periodically for security
- **Limit access** to the `.env` file and Azure resources
- **Use HTTPS only** when transmitting the key

## Authentication Status

⚠️ **Note**: During testing, it was observed that LiteLLM may accept requests even with invalid keys. This suggests that authentication might not be fully enforced in the current configuration. This should be investigated further for production use.

For the PoC, the secure key infrastructure is in place and working correctly.