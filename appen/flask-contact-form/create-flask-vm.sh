#!/bin/bash

# Configuration
RESOURCE_GROUP="flask-app-rg"
VM_NAME="flask-vm"
LOCATION="swedencentral"

# Create resource group
echo "Creating resource group..."
az group create \
  --name $RESOURCE_GROUP \
  --location $LOCATION

# Create VM with Ubuntu 24.04
echo "Creating VM (this takes a few minutes)..."
az vm create \
  --resource-group $RESOURCE_GROUP \
  --name $VM_NAME \
  --image Ubuntu2404 \
  --size Standard_D2s_v3 \
  --admin-username azureuser \
  --generate-ssh-keys

# Open port 5001 for the Flask application
echo "Opening port 5001..."
az vm open-port \
  --resource-group $RESOURCE_GROUP \
  --name $VM_NAME \
  --port 5001

# Get and display the public IP
IP_ADDRESS=$(az vm show \
  --resource-group $RESOURCE_GROUP \
  --name $VM_NAME \
  --show-details \
  --query publicIps \
  --output tsv)

echo ""
echo "======================================"
echo "VM created successfully!"
echo "======================================"
echo "Public IP: $IP_ADDRESS"
echo ""
echo "Connect with: ssh azureuser@$IP_ADDRESS"
echo "Delete with:  az group delete --name $RESOURCE_GROUP --yes"
