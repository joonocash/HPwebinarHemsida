#!/bin/bash

# ===================================================
# 1. KONFIGURATION & VARIABLER
# ===================================================

# AZURE INFRASTRUKTUR VARIABLER
RESOURCE_GROUP="flask-app-rg"
VM_NAME="flask-vm"
LOCATION="swedencentral"

# DATABAS VARIABLER (Nytt, förhoppningsvis unikt namn)
SERVER_NAME="flask-db-hp-2025"  
ADMIN_USER="flaskadmin"
ADMIN_PASSWORD="EnDumKod123" 
DATABASE_NAME="contactform"

# VM & APP VARIABLER
VM_USER="azureuser" 

# Beräknade värden
DB_ENDPOINT="${SERVER_NAME}.postgres.database.azure.com"
CONNECTION_STRING="postgresql://${ADMIN_USER}:${ADMIN_PASSWORD}@${DB_ENDPOINT}:5432/${DATABASE_NAME}"


echo "--- STARTAR END-TO-END AZURE DEPLOYMENT ---"
echo "VM-namn: ${VM_NAME}"
echo "Nytt DB Servernamn: ${SERVER_NAME}"
echo "Anslutningssträng: ${CONNECTION_STRING}"
echo "-------------------------------------------"


# ===================================================
# 2. PROVISIONERA VM OCH DATABAS (AZURE CLI)
# ===================================================

echo "--- 2.1 Skapar Resursgrupp: ${RESOURCE_GROUP} ---"
az group create \
  --name $RESOURCE_GROUP \
  --location $LOCATION

# -----------------------------------------------
# 2.2 SKAPA OCH KONFIGURERA AZURE VM
# -----------------------------------------------

echo "--- 2.2 Skapar VM (${VM_NAME}) med Ubuntu 24.04 (detta tar några minuter)..."
az vm create \
  --resource-group $RESOURCE_GROUP \
  --name $VM_NAME \
  --image Ubuntu2404 \
  --size Standard_D2s_v3 \
  --admin-username $VM_USER \
  --generate-ssh-keys

# Öppna port 5001 för Flask-applikationen (VM:ens NSG)
echo "Öppnar port 5001 i VM:ens Network Security Group (NSG)..."
az vm open-port \
  --resource-group $RESOURCE_GROUP \
  --name $VM_NAME \
  --port 5001

# Hämta och spara den publika IP-adressen
IP_ADDRESS=$(az vm show \
  --resource-group $RESOURCE_GROUP \
  --name $VM_NAME \
  --show-details \
  --query publicIps \
  --output tsv)

if [ -z "$IP_ADDRESS" ]; then
    echo "FEL: Kunde inte hämta VM:ens IP-adress. Avbryter."
    exit 1
fi

VM_IP=$IP_ADDRESS
echo "VM KLAR. Publik IP: $VM_IP"

# *** LÄGG TILL PAUS HÄR FÖR ATT FÖRHINDRA SSH-FEL ***
echo "Väntar 30 sekunder på att SSH-tjänsten ska starta helt på VM:en..."
sleep 30
# ************************************************************

# -----------------------------------------------
# 2.3 SKAPA AZURE POSTGRESQL FLEXIBLE SERVER
# -----------------------------------------------

echo "--- 2.3 Skapar PostgreSQL Server (detta kan ta 3-5 minuter) ---"
az postgres flexible-server create \
  --resource-group $RESOURCE_GROUP \
  --name $SERVER_NAME \
  --location $LOCATION \
  --admin-user $ADMIN_USER \
  --admin-password $ADMIN_PASSWORD \
  --sku-name Standard_B1ms \
  --tier Burstable \
  --version 17 \
  --public-access 0.0.0.0 
  
if [ $? -ne 0 ]; then
    echo "FEL: Misslyckades med att skapa PostgreSQL-servern. Kontrollera Azure CLI-utdata ovan. Servernamnet '${SERVER_NAME}' kanske är upptaget."
    exit 1
fi

echo "--- 2.4 Skapar Applikationsdatabasen ---"
az postgres flexible-server db create \
  --resource-group $RESOURCE_GROUP \
  --server-name $SERVER_NAME \
  --database-name $DATABASE_NAME

# SKAPAR BRANDVÄGGSREGEL: TILLÅT ALLA IP-ADRESSER (INTERNET)
echo "--- 2.5 SKAPAR BRANDVÄGGSREGEL: TILLÅT ALLA IP-ADRESSER (0.0.0.0 till 255.255.255.255) ---"
az postgres flexible-server firewall-rule create \
  --resource-group $RESOURCE_GROUP \
  --name $SERVER_NAME \
  --rule-name AllowAllInternetIPs \
  --start-ip-address 0.0.0.0 \
  --end-ip-address 255.255.255.255

echo "Azure-provisionering KLAR. Väntar 10 sekunder på att brandväggsregler ska spridas..."
sleep 10


# ===================================================
# 3. FÖRBERED VM OCH DEPLOY APPLIKATION (SSH/SCP)
# ===================================================

echo "--- 3.1 Överför befintliga filer (app.py och requirements.txt) till VM:en ---"
# *** FIX: Lägger till StrictHostKeyChecking=no för att ignorera värdnyckelvarning ***
scp -o StrictHostKeyChecking=no app.py requirements.txt ${VM_USER}@${VM_IP}:~/
if [ $? -ne 0 ]; then
    echo "FEL: Misslyckades med SCP-överföringen. Kontrollera att dina SSH-nycklar är giltiga."
    exit 1
fi

echo "--- 3.2 Loggar in i VM och installerar systempaket/Python-miljö ---"
# *** FIX: Lägger till StrictHostKeyChecking=no för att ignorera SSH-varning i blocket ***
ssh -o StrictHostKeyChecking=no ${VM_USER}@${VM_IP} << EOF_SSH
  # 1. Installera nödvändiga systempaket (Python, pip, venv)
  echo "Uppdaterar systempaket och installerar Python venv/pip..."
  sudo apt update -y
  sudo apt install python3 python3-pip python3-venv -y
  
  # 2. Skapa och aktivera virtuell miljö
  echo "Skapar virtuell miljö (venv)..."
  python3 -m venv venv
  source venv/bin/activate
  
  # 3. Installera Python dependencies (från din befintliga requirements.txt)
  echo "Installerar Python dependencies..."
  pip install -r requirements.txt
  
  # 4. Skapa systemd miljö- och enhetsfiler
  echo "Skapar systemd konfigurationsfiler på VM:en..."
  
  # Skapa konfigurationsmapp och miljöfil (för säker lagring av CONNECTION_STRING)
  sudo mkdir -p /etc/flask-contact-form
  echo "DATABASE_URL=$CONNECTION_STRING" | sudo tee /etc/flask-contact-form/environment > /dev/null
  sudo chmod 600 /etc/flask-contact-form/environment
  sudo chown root:root /etc/flask-contact-form/environment
  
  # Skapa systemd enhetsfil
  sudo tee /etc/systemd/system/flask-contact-form.service > /dev/null << 'EOF_UNIT'
[Unit]
Description=Flask Contact Form Application
After=network.target

[Service]
User=azureuser
Group=azureuser
WorkingDirectory=/home/azureuser
EnvironmentFile=/etc/flask-contact-form/environment
ExecStart=/home/azureuser/venv/bin/gunicorn --workers 2 --bind 0.0.0.0:5001 app:app
Restart=always
RestartSec=10

[Install]
WantedBy=multi-user.target
EOF_UNIT
  
  # 5. Ladda om, aktivera och starta tjänsten
  sudo systemctl daemon-reload
  sudo systemctl enable flask-contact-form
  sudo systemctl start flask-contact-form
  
  echo "---------------------------------------------------"
  echo "Systemd service 'flask-contact-form' är startad och aktiverad."
  echo "Kontrollera statusen:"
  sudo systemctl status flask-contact-form --no-pager
  
EOF_SSH


echo "==================================================="
echo "--- FULLSTÄNDIG DEPLOYMENT KLAR! ---"
echo "==================================================="
echo "Din Flask-applikation bör nu vara tillgänglig på:"
echo "➡️  http://${VM_IP}:5001/"
echo ""
echo "För att kontrollera loggar eller ansluta:"
echo "SSH: ssh ${VM_USER}@${VM_IP}"
echo "Loggar: sudo journalctl -u flask-contact-form -f"
echo ""
echo "⚠️  Kom ihåg att städa upp när du är klar:"
echo "⚠️  az group delete --name ${RESOURCE_GROUP} --yes --no-wait"