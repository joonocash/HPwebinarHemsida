#!/bin/bash

# ===============================================
# SÄKER AZURE NÄTVERK DEPLOYMENT SCRIPT
# Region: swedencentral, VM Size: Standard_D2s_v3
# ===============================================

# --- 1. Konfigurera Variabler ---
RESOURCE_GROUP="DemoRG"
LOCATION="swedencentral" # Uppdaterad Region
VNET_NAME="DemoVNet"
SUBNET_NAME="default"
ADMIN_USERNAME="azureuser"
NSG_NAME="DemoNSG"
IMAGE="Ubuntu2204"
VM_SIZE="Standard_D2s_v3" # Uppdaterad VM Storlek

echo "======================================================="
echo " Startar Azure Deployment i region $LOCATION"
echo " VM Storlek: $VM_SIZE"
echo " Resursgrupp: $RESOURCE_GROUP"
echo "======================================================="

# Skapa Resursgrupp
echo "--> 1. Skapar Resursgrupp..."
az group create --name $RESOURCE_GROUP --location $LOCATION

# Skapa VNet och Subnet
echo "--> 2. Skapar Virtuellt Nätverk ($VNET_NAME)..."
az network vnet create \
  --resource-group $RESOURCE_GROUP \
  --name $VNET_NAME \
  --address-prefix 10.0.0.0/16 \
  --subnet-name $SUBNET_NAME \
  --subnet-prefix 10.0.0.0/24

# --- 2. Konfigurera Nätverkssäkerhet (NSG/ASG) ---
echo "--> 3. Konfigurerar Nätverkssäkerhetsgrupper (NSG & ASG)..."

# Skapa ASGs (Application Security Groups)
az network asg create \
  --resource-group $RESOURCE_GROUP \
  --name ReverseProxyASG
az network asg create \
  --resource-group $RESOURCE_GROUP \
  --name BastionHostASG

# Skapa NSG
az network nsg create \
  --resource-group $RESOURCE_GROUP \
  --name $NSG_NAME

# Lägg till SSH access regel (Endast till Bastion)
az network nsg rule create \
  --resource-group $RESOURCE_GROUP \
  --nsg-name $NSG_NAME \
  --name AllowSSH \
  --priority 1000 \
  --access Allow \
  --protocol Tcp \
  --direction Inbound \
  --source-address-prefixes Internet \
  --source-port-ranges "*" \
  --destination-asg BastionHostASG \
  --destination-port-ranges 22 \
  --output none

# Lägg till HTTP access regel (Endast till Reverse Proxy)
az network nsg rule create \
  --resource-group $RESOURCE_GROUP \
  --nsg-name $NSG_NAME \
  --name AllowHTTP \
  --priority 2000 \
  --access Allow \
  --protocol Tcp \
  --direction Inbound \
  --source-address-prefixes Internet \
  --source-port-ranges "*" \
  --destination-asg ReverseProxyASG \
  --destination-port-ranges 80 \
  --output none

# Koppla NSG till Subnet
echo "    Associerar $NSG_NAME med $SUBNET_NAME..."
az network vnet subnet update \
  --resource-group $RESOURCE_GROUP \
  --vnet-name $VNET_NAME \
  --name $SUBNET_NAME \
  --network-security-group $NSG_NAME \
  --output none

# --- 3. Provisionera Virtuella Maskiner ---
echo "--> 4. Provisionerar Virtuella Maskiner. Storlek: $VM_SIZE..."

# Web Server (Ingen Publik IP, konfigureras med cloud-init)
echo "    - Skapar WebServer (Internt, port 8080)..."
az vm create \
  --resource-group $RESOURCE_GROUP \
  --name WebServer \
  --image $IMAGE \
  --size $VM_SIZE \
  --admin-username $ADMIN_USERNAME \
  --vnet-name $VNET_NAME \
  --subnet $SUBNET_NAME \
  --nsg "" \
  --public-ip-address "" \
  --generate-ssh-keys \
  --custom-data @web_server_config.yaml \
  --no-wait

# Reverse Proxy (Publik IP, konfigureras med cloud-init)
echo "    - Skapar ReverseProxy (Publik IP, port 80)..."
az vm create \
  --resource-group $RESOURCE_GROUP \
  --name ReverseProxy \
  --image $IMAGE \
  --size $VM_SIZE \
  --admin-username $ADMIN_USERNAME \
  --vnet-name $VNET_NAME \
  --subnet $SUBNET_NAME \
  --nsg "" \
  --generate-ssh-keys \
  --custom-data @reverse_proxy_config.yaml \
  --no-wait

# Bastion Host (Publik IP)
echo "    - Skapar BastionHost (Publik IP, port 22)..."
az vm create \
  --resource-group $RESOURCE_GROUP \
  --name BastionHost \
  --image $IMAGE \
  --size $VM_SIZE \
  --admin-username $ADMIN_USERNAME \
  --vnet-name $VNET_NAME \
  --subnet $SUBNET_NAME \
  --nsg "" \
  --generate-ssh-keys \
  --no-wait

echo "    Väntar på att VM:arna ska skapas (ca 2 minuter)..."
az vm wait --resource-group $RESOURCE_GROUP --name WebServer --created
az vm wait --resource-group $RESOURCE_GROUP --name ReverseProxy --created
az vm wait --resource-group $RESOURCE_GROUP --name BastionHost --created
sleep 10 # Extra väntetid för att säkerställa att alla nätverksresurser är redo

# --- 4. Koppla ASGs till Nätverkskort (NIC) ---
echo "--> 5. Kopplar ASGs till Nätverkskorten..."

# --- Reverse Proxy ---
echo "    - Kopplar ReverseProxyASG..."
REVERSE_PROXY_NIC_ID=$(az vm show --resource-group $RESOURCE_GROUP --name ReverseProxy --query 'networkProfile.networkInterfaces[0].id' -o tsv)
REVERSE_PROXY_NIC_NAME=$(basename $REVERSE_PROXY_NIC_ID)
REVERSE_PROXY_NIC_IP_CONFIG=$(az network nic show --resource-group $RESOURCE_GROUP --name $REVERSE_PROXY_NIC_NAME --query 'ipConfigurations[0].name' -o tsv)

az network nic ip-config update \
  --resource-group $RESOURCE_GROUP \
  --nic-name $REVERSE_PROXY_NIC_NAME \
  --name $REVERSE_PROXY_NIC_IP_CONFIG \
  --application-security-groups ReverseProxyASG \
  --output none

# --- Bastion Host ---
echo "    - Kopplar BastionHostASG..."
BASTION_HOST_NIC_ID=$(az vm show --resource-group $RESOURCE_GROUP --name BastionHost --query 'networkProfile.networkInterfaces[0].id' -o tsv)
BASTION_HOST_NIC_NAME=$(basename $BASTION_HOST_NIC_ID)
BASTION_HOST_NIC_IP_CONFIG=$(az network nic show --resource-group $RESOURCE_GROUP --name $BASTION_HOST_NIC_NAME --query 'ipConfigurations[0].name' -o tsv)

az network nic ip-config update \
  --resource-group $RESOURCE_GROUP \
  --nic-name $BASTION_HOST_NIC_NAME \
  --name $BASTION_HOST_NIC_IP_CONFIG \
  --application-security-groups BastionHostASG \
  --output none

# --- 5. Slutgiltig Testinformation ---
REVERSE_PROXY_IP=$(az vm show \
  --resource-group $RESOURCE_GROUP \
  --name ReverseProxy \
  --show-details \
  --query 'publicIps' \
  --output tsv)

BASTION_IP=$(az vm show \
  --resource-group $RESOURCE_GROUP \
  --name BastionHost \
  --show-details \
  --query 'publicIps' \
  --output tsv)

echo "======================================================="
echo " Deployment är SLUTFÖRD! 🎉"
echo "-------------------------------------------------------"
echo " ✅ Test HTTP-åtkomst (Webbserver via Reverse Proxy):"
echo "    http://$REVERSE_PROXY_IP"
echo ""
echo " ✅ Test SSH-åtkomst (Endast via Bastion Host):"
echo "    ssh $ADMIN_USERNAME@$BASTION_IP"
echo "-------------------------------------------------------"
echo " Glöm inte att städa upp resurserna när du är klar:"
echo " az group delete --name $RESOURCE_GROUP --yes --no-wait"
echo "======================================================="