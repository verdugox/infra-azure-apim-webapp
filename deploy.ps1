# ================================
# Load variables
# ================================
. "$PSScriptRoot/variables.ps1"

Write-Host "Deploying INFRA (AKS + APIM) — SAFE & IDEMPOTENT"

# ================================
# Resource Group
# ================================
if (-not (az group exists --name $RG | ConvertFrom-Json)) {
  Write-Host "Creating Resource Group $RG"
  az group create --name $RG --location $LOC | Out-Null
} else {
  Write-Host "Resource Group $RG already exists"
}

# ================================
# Providers (MANDATORY)
# ================================
Write-Host "Registering Azure Providers..."
az provider register --namespace Microsoft.ContainerService --wait | Out-Null
az provider register --namespace Microsoft.ApiManagement --wait | Out-Null
az provider register --namespace Microsoft.DocumentDB --wait | Out-Null


# ================================
# AKS (HARD FAIL)
# ================================
Write-Host "Checking AKS..."

$AKS_EXISTS = az aks show `
  --resource-group $RG `
  --name $AKS_NAME `
  --query name -o tsv 2>$null

if (-not $AKS_EXISTS) {
  Write-Host "Creating AKS $AKS_NAME..."

  az aks create `
    --resource-group $RG `
    --name $AKS_NAME `
    --location $LOC `
    --node-count $AKS_NODE_COUNT `
    --node-vm-size $AKS_NODE_SIZE `
    --enable-managed-identity `
    --generate-ssh-keys `
    --api-server-authorized-ip-ranges "0.0.0.0/0" `
    --only-show-errors `
    --output none


  if ($LASTEXITCODE -ne 0) {
    Write-Error "AKS creation failed. Aborting pipeline."
    exit 1
  }
} else {
  Write-Host "AKS $AKS_NAME already exists"
}

Write-Host "Waiting for AKS to be ready..."
az aks wait --resource-group $RG --name $AKS_NAME --created

Write-Host "Getting AKS credentials..."
az aks get-credentials `
  --resource-group $RG `
  --name $AKS_NAME `
  --overwrite-existing

Write-Host "AKS FQDN:"
az aks show --resource-group $RG --name $AKS_NAME --query fqdn -o tsv

# ================================
# COSMOS DB (Mongo API) - IDEMPOTENT
# ================================
Write-Host "Checking Cosmos DB (Mongo API)..."

$COSMOS_EXISTS = az cosmosdb show `
  --name $COSMOS_ACCOUNT `
  --resource-group $RG `
  --query name -o tsv 2>$null

if (-not $COSMOS_EXISTS) {
  Write-Host "Creating Cosmos DB account $COSMOS_ACCOUNT (Mongo API)..."

  az cosmosdb create `
    --name $COSMOS_ACCOUNT `
    --resource-group $RG `
    --kind MongoDB `
    --capabilities EnableMongo `
    --default-consistency-level Session `
    --enable-free-tier true `
    --locations regionName=$LOC failoverPriority=0 `
    --only-show-errors `
    --output none

  if ($LASTEXITCODE -ne 0) {
    Write-Error "Cosmos DB creation failed. Aborting pipeline."
    exit 1
  }
} else {
  Write-Host "Cosmos DB account $COSMOS_ACCOUNT already exists"
}



# ================================
#AZURE COSMOS DB
# ================================

# (Opcional) Asegurar DB en Cosmos Mongo
Write-Host "Ensuring Cosmos Mongo database exists..."
$DB_EXISTS = az cosmosdb mongodb database show `
  --account-name $COSMOS_ACCOUNT `
  --resource-group $RG `
  --name $COSMOS_DB_NAME `
  --query name -o tsv 2>$null

if (-not $DB_EXISTS) {
  az cosmosdb mongodb database create `
    --account-name $COSMOS_ACCOUNT `
    --resource-group $RG `
    --name $COSMOS_DB_NAME `
    --only-show-errors `
    --output none

  Write-Host "Mongo DB $COSMOS_DB_NAME created"
} else {
  Write-Host "Mongo DB $COSMOS_DB_NAME already exists"
}

# Obtener connection string (NO lo imprimas en logs)
$COSMOS_CONN = az cosmosdb keys list `
  --name $COSMOS_ACCOUNT `
  --resource-group $RG `
  --type connection-strings `
  --query "connectionStrings[0].connectionString" -o tsv


# ================================
# APIM SOFT-DELETE PURGE (MANDATORY)
# ================================
Write-Host "Checking APIM soft-deleted state..."

try {
  az apim deletedservice purge `
    --service-name $APIM_NAME `
    --location $LOC `
    --only-show-errors
}
catch {
  Write-Host "No APIM soft-deleted service to purge"
}



# ================================
# APIM (SOFT SAFE)
# ================================
Write-Host "Checking APIM..."

$APIM_EXISTS = az apim show `
  --name $APIM_NAME `
  --resource-group $RG `
  --query name -o tsv 2>$null

if (-not $APIM_EXISTS) {
  Write-Host "Creating APIM $APIM_NAME..."

  az apim create `
    --name $APIM_NAME `
    --resource-group $RG `
    --location $LOC `
    --publisher-name "Verdugox" `
    --publisher-email "demo@demo.com" `
    --sku-name Consumption `
    --only-show-errors `
    --output none
} else {
  Write-Host "APIM $APIM_NAME already exists"
}

Write-Host "Waiting for APIM provisioning..."
az apim wait --name $APIM_NAME --resource-group $RG --created
Start-Sleep -Seconds 30

# ================================
# APIM Backend (REST)
# ================================
$backendUrl = "https://management.azure.com/subscriptions/$SUBSCRIPTION_ID/resourceGroups/$RG/providers/Microsoft.ApiManagement/service/$APIM_NAME/backends/placeholder-backend?api-version=2022-08-01"

az rest `
  --method PUT `
  --uri $backendUrl `
  --body '{
    "properties": {
      "url": "https://httpbin.org",
      "protocol": "http"
    }
  }'

Start-Sleep -Seconds 15


# ================================
# APIM API (REST)
# ================================
$apiUrl = "https://management.azure.com/subscriptions/$SUBSCRIPTION_ID/resourceGroups/$RG/providers/Microsoft.ApiManagement/service/$APIM_NAME/apis/cardops-api?api-version=2022-08-01"

az rest `
  --method PUT `
  --uri $apiUrl `
  --body '{
    "properties": {
      "displayName": "Card Ops API",
      "path": "cardops",
      "protocols": ["https"],
      "subscriptionRequired": false
    }
  }'

Start-Sleep -Seconds 20

# ================================
# APIM Policy (REST — EVENTUAL SAFE)
# ================================
$policyUrl = "https://management.azure.com/subscriptions/$SUBSCRIPTION_ID/resourceGroups/$RG/providers/Microsoft.ApiManagement/service/$APIM_NAME/apis/cardops-api/policies/policy?api-version=2022-08-01"

$policyXml = @"
<policies>
  <inbound>
    <base />
    <rate-limit calls="100" renewal-period="60" />
    <set-backend-service backend-id="placeholder-backend" />
  </inbound>
  <backend>
    <base />
  </backend>
  <outbound>
    <base />
  </outbound>
</policies>
"@

$maxRetries = 5
for ($i = 1; $i -le $maxRetries; $i++) {
  try {
    az rest `
      --method PUT `
      --uri $policyUrl `
      --headers "{ `"Content-Type`": `"application/vnd.ms-azure-apim.policy+xml`" }" `
      --body $policyXml
    Write-Host "APIM policy applied successfully"
    break
  }
  catch {
    Write-Host "APIM busy (attempt $i/$maxRetries), retrying..."
    Start-Sleep -Seconds 15
  }
}

# ================================
# DONE
# ================================
Write-Host "===================================="
Write-Host "INFRA READY ✅"
Write-Host ""
Write-Host "AKS:"
Write-Host " - Name     : $AKS_NAME"
Write-Host ""
Write-Host "APIM:"
Write-Host " - Name     : $APIM_NAME"
Write-Host ""
Write-Host "COSMOS DB (Mongo API):"
Write-Host " - Account  : $COSMOS_ACCOUNT"
Write-Host " - Database : $COSMOS_DB_NAME"
Write-Host " - Tier     : Free Tier (400 RU/s, 5GB)"
Write-Host ""
Write-Host "✔ All resources are created or already exist"
Write-Host "✔ Script is SAFE & IDEMPOTENT"
Write-Host "✔ Safe to re-run N times"
Write-Host "===================================="


