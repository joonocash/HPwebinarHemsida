#!/bin/bash

# ===================================================
# ULTIMATE AZURE DEPLOYMENT SCRIPT - FIXED VERSION
# Harry Potter Webinar Site + Flask Backend
# ===================================================

set -e  # Exit on any error

# --- CONFIGURATION ---
RESOURCE_GROUP="HPWebinar-RG"
LOCATION="swedencentral"
VNET_NAME="HPWebinar-VNet"
SUBNET_NAME="AppSubnet"
NSG_NAME="HPWebinar-NSG"
ADMIN_USERNAME="azureuser"
VM_SIZE="Standard_D2s_v3"
IMAGE="Ubuntu2404"

# Database Configuration
DB_SERVER_NAME="hpwebinar-db-$(date +%s)"  # Unique name with timestamp
DB_ADMIN_USER="hpadmin"
DB_ADMIN_PASSWORD="MagicPassword123!"
DB_NAME="webinarregistrations"

# VM Names
FLASK_VM_NAME="FlaskBackend"
WEB_VM_NAME="WebFrontend"
BASTION_VM_NAME="BastionHost"

echo "=========================================="
echo "🧙 HARRY POTTER WEBINAR DEPLOYMENT"
echo "=========================================="
echo "Resource Group: $RESOURCE_GROUP"
echo "Location: $LOCATION"
echo "Database Server: $DB_SERVER_NAME"
echo "=========================================="

# Ensure SSH agent is running and key is added
echo "🔑 Checking SSH configuration..."
if [ -z "$SSH_AUTH_SOCK" ]; then
  echo "   Starting SSH agent..."
  eval $(ssh-agent -s)
fi

# Add default SSH key if it exists
if [ -f ~/.ssh/id_rsa ]; then
  ssh-add ~/.ssh/id_rsa 2>/dev/null
  echo "   ✅ SSH key added (id_rsa)"
elif [ -f ~/.ssh/id_ed25519 ]; then
  ssh-add ~/.ssh/id_ed25519 2>/dev/null
  echo "   ✅ SSH key added (id_ed25519)"
else
  echo "   Adding default key..."
  ssh-add 2>/dev/null
fi

echo "   SSH agent ready"

# --- 1. CREATE RESOURCE GROUP ---
echo "📦 Step 1: Creating Resource Group..."
az group create \
  --name $RESOURCE_GROUP \
  --location $LOCATION \
  --output none

# --- 2. CREATE NETWORK INFRASTRUCTURE ---
echo "🌐 Step 2: Creating Virtual Network..."
az network vnet create \
  --resource-group $RESOURCE_GROUP \
  --name $VNET_NAME \
  --address-prefix 10.0.0.0/16 \
  --subnet-name $SUBNET_NAME \
  --subnet-prefix 10.0.0.0/24 \
  --output none

# --- 3. CREATE NETWORK SECURITY GROUP ---
echo "🔒 Step 3: Creating Network Security Group..."
az network nsg create \
  --resource-group $RESOURCE_GROUP \
  --name $NSG_NAME \
  --output none

# Create ASGs for better security
az network asg create \
  --resource-group $RESOURCE_GROUP \
  --name WebFrontendASG \
  --output none

az network asg create \
  --resource-group $RESOURCE_GROUP \
  --name FlaskBackendASG \
  --output none

az network asg create \
  --resource-group $RESOURCE_GROUP \
  --name BastionASG \
  --output none

# Allow HTTP to Web Frontend
az network nsg rule create \
  --resource-group $RESOURCE_GROUP \
  --nsg-name $NSG_NAME \
  --name AllowHTTP \
  --priority 1000 \
  --access Allow \
  --protocol Tcp \
  --direction Inbound \
  --source-address-prefixes Internet \
  --destination-asg WebFrontendASG \
  --destination-port-ranges 80 \
  --output none

# Allow SSH to Bastion only
az network nsg rule create \
  --resource-group $RESOURCE_GROUP \
  --nsg-name $NSG_NAME \
  --name AllowSSH \
  --priority 1100 \
  --access Allow \
  --protocol Tcp \
  --direction Inbound \
  --source-address-prefixes Internet \
  --destination-asg BastionASG \
  --destination-port-ranges 22 \
  --output none

# Associate NSG with subnet
az network vnet subnet update \
  --resource-group $RESOURCE_GROUP \
  --vnet-name $VNET_NAME \
  --name $SUBNET_NAME \
  --network-security-group $NSG_NAME \
  --output none

# --- 4. CREATE POSTGRESQL DATABASE ---
echo "🗄️  Step 4: Creating PostgreSQL Database (this takes 3-5 minutes)..."
az postgres flexible-server create \
  --resource-group $RESOURCE_GROUP \
  --name $DB_SERVER_NAME \
  --location $LOCATION \
  --admin-user $DB_ADMIN_USER \
  --admin-password $DB_ADMIN_PASSWORD \
  --sku-name Standard_B1ms \
  --tier Burstable \
  --version 17 \
  --public-access 0.0.0.0-255.255.255.255 \
  --output none

echo "   Creating database..."
az postgres flexible-server db create \
  --resource-group $RESOURCE_GROUP \
  --server-name $DB_SERVER_NAME \
  --database-name $DB_NAME \
  --output none

# Database connection string
DB_CONNECTION_STRING="postgresql://${DB_ADMIN_USER}:${DB_ADMIN_PASSWORD}@${DB_SERVER_NAME}.postgres.database.azure.com:5432/${DB_NAME}"

echo "   ✅ Database ready!"

# --- 5. CREATE CLOUD-INIT CONFIGS ---
echo "📝 Step 5: Preparing VM configurations..."

# Flask Backend cloud-init
cat > flask-config.yaml << EOF
#cloud-config
packages:
  - python3
  - python3-pip
  - python3-venv
  - nginx

write_files:
  - path: /home/azureuser/app.py
    content: |
      import os
      from datetime import datetime
      from flask import Flask, request, jsonify
      from flask_sqlalchemy import SQLAlchemy
      from flask_cors import CORS

      app = Flask(__name__)
      CORS(app)

      app.config['SQLALCHEMY_DATABASE_URI'] = os.environ.get('DATABASE_URL', 'sqlite:///registrations.db')
      app.config['SQLALCHEMY_TRACK_MODIFICATIONS'] = False

      db = SQLAlchemy(app)

      class Registration(db.Model):
          id = db.Column(db.Integer, primary_key=True)
          name = db.Column(db.String(100), nullable=False)
          email = db.Column(db.String(120), nullable=False)
          company = db.Column(db.String(100))
          address = db.Column(db.String(200))
          job_title = db.Column(db.String(100))
          created_at = db.Column(db.DateTime, default=datetime.utcnow)

      with app.app_context():
          db.create_all()

      @app.route('/api/register', methods=['POST'])
      def register():
          try:
              data = request.get_json()
              registration = Registration(
                  name=data.get('name'),
                  email=data.get('email'),
                  company=data.get('company', ''),
                  address=data.get('address', ''),
                  job_title=data.get('job_title', '')
              )
              db.session.add(registration)
              db.session.commit()
              return jsonify({'success': True, 'message': 'Registration successful!'}), 200
          except Exception as e:
              return jsonify({'success': False, 'message': str(e)}), 500

      @app.route('/api/registrations', methods=['GET'])
      def get_registrations():
          registrations = Registration.query.order_by(Registration.created_at.desc()).all()
          return jsonify([{
              'id': r.id,
              'name': r.name,
              'email': r.email,
              'company': r.company,
              'address': r.address,
              'job_title': r.job_title,
              'created_at': r.created_at.isoformat()
          } for r in registrations])

      @app.route('/health')
      def health():
          return jsonify({'status': 'healthy'}), 200

      if __name__ == '__main__':
          app.run(host='0.0.0.0', port=5000)

  - path: /home/azureuser/requirements.txt
    content: |
      flask
      gunicorn
      flask-sqlalchemy
      flask-cors
      psycopg2-binary

  - path: /etc/systemd/system/flask-app.service
    content: |
      [Unit]
      Description=Flask Registration Backend
      After=network.target

      [Service]
      User=azureuser
      WorkingDirectory=/home/azureuser
      Environment="DATABASE_URL=${DB_CONNECTION_STRING}"
      ExecStart=/home/azureuser/venv/bin/gunicorn --workers 2 --bind 0.0.0.0:5000 app:app
      Restart=always
      RestartSec=10

      [Install]
      WantedBy=multi-user.target

  - path: /etc/nginx/sites-available/default
    content: |
      server {
        listen 5000;
        location / {
          proxy_pass http://127.0.0.1:5000;
          proxy_set_header Host \$host;
          proxy_set_header X-Real-IP \$remote_addr;
        }
      }

runcmd:
  - cd /home/azureuser
  - python3 -m venv venv
  - source venv/bin/activate && pip install -r requirements.txt
  - chown -R azureuser:azureuser /home/azureuser
  - systemctl daemon-reload
  - systemctl enable flask-app
  - systemctl start flask-app
EOF

# Web Frontend cloud-init
cat > web-config.yaml << 'EOF'
#cloud-config
packages:
  - nginx
  - git

write_files:
  - path: /etc/nginx/sites-available/default
    content: |
      server {
        listen 80 default_server;
        server_name _;
        root /var/www/html;
        index index.html;

        location / {
          try_files $uri $uri/ =404;
        }

        # Proxy API calls to Flask backend
        location /api/ {
          proxy_pass http://FLASK_IP_PLACEHOLDER:5000;
          proxy_set_header Host $host;
          proxy_set_header X-Real-IP $remote_addr;
          proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
        }
      }

runcmd:
  - systemctl restart nginx
  - mkdir -p /var/www/html
EOF

echo "   ✅ Configurations ready!"

# --- 6. CREATE VMs ---
echo "🖥️  Step 6: Creating Virtual Machines..."

# Flask Backend VM
echo "   Creating Flask Backend VM..."
az vm create \
  --resource-group $RESOURCE_GROUP \
  --name $FLASK_VM_NAME \
  --image $IMAGE \
  --size $VM_SIZE \
  --admin-username $ADMIN_USERNAME \
  --vnet-name $VNET_NAME \
  --subnet $SUBNET_NAME \
  --nsg "" \
  --public-ip-address "" \
  --generate-ssh-keys \
  --custom-data flask-config.yaml \
  --output none \
  --no-wait

# Web Frontend VM
echo "   Creating Web Frontend VM..."
az vm create \
  --resource-group $RESOURCE_GROUP \
  --name $WEB_VM_NAME \
  --image $IMAGE \
  --size $VM_SIZE \
  --admin-username $ADMIN_USERNAME \
  --vnet-name $VNET_NAME \
  --subnet $SUBNET_NAME \
  --nsg "" \
  --generate-ssh-keys \
  --custom-data web-config.yaml \
  --output none \
  --no-wait

# Bastion Host VM
echo "   Creating Bastion Host VM..."
az vm create \
  --resource-group $RESOURCE_GROUP \
  --name $BASTION_VM_NAME \
  --image $IMAGE \
  --size $VM_SIZE \
  --admin-username $ADMIN_USERNAME \
  --vnet-name $VNET_NAME \
  --subnet $SUBNET_NAME \
  --nsg "" \
  --generate-ssh-keys \
  --output none \
  --no-wait

echo "   Waiting for VMs to be created..."
az vm wait --resource-group $RESOURCE_GROUP --name $FLASK_VM_NAME --created
az vm wait --resource-group $RESOURCE_GROUP --name $WEB_VM_NAME --created
az vm wait --resource-group $RESOURCE_GROUP --name $BASTION_VM_NAME --created

sleep 30  # Wait for VMs to fully initialize

# --- 7. CONFIGURE ASGs ---
echo "🔗 Step 7: Configuring Application Security Groups..."

# Helper function to associate NIC with ASG
associate_asg() {
  local vm_name=$1
  local asg_name=$2
  
  local nic_id=$(az vm show --resource-group $RESOURCE_GROUP --name $vm_name --query 'networkProfile.networkInterfaces[0].id' -o tsv)
  local nic_name=$(basename $nic_id)
  local ip_config=$(az network nic show --resource-group $RESOURCE_GROUP --name $nic_name --query 'ipConfigurations[0].name' -o tsv)
  
  az network nic ip-config update \
    --resource-group $RESOURCE_GROUP \
    --nic-name $nic_name \
    --name $ip_config \
    --application-security-groups $asg_name \
    --output none
}

associate_asg $FLASK_VM_NAME FlaskBackendASG
associate_asg $WEB_VM_NAME WebFrontendASG
associate_asg $BASTION_VM_NAME BastionASG

# --- 8. GET IP ADDRESSES ---
echo "📍 Step 8: Retrieving IP addresses..."

FLASK_PRIVATE_IP=$(az vm show --resource-group $RESOURCE_GROUP --name $FLASK_VM_NAME --show-details --query 'privateIps' -o tsv)
WEB_PRIVATE_IP=$(az vm show --resource-group $RESOURCE_GROUP --name $WEB_VM_NAME --show-details --query 'privateIps' -o tsv)
WEB_PUBLIC_IP=$(az vm show --resource-group $RESOURCE_GROUP --name $WEB_VM_NAME --show-details --query 'publicIps' -o tsv)
BASTION_PUBLIC_IP=$(az vm show --resource-group $RESOURCE_GROUP --name $BASTION_VM_NAME --show-details --query 'publicIps' -o tsv)

echo "   Flask Backend (private): $FLASK_PRIVATE_IP"
echo "   Web Frontend (private): $WEB_PRIVATE_IP"
echo "   Web Frontend (public): $WEB_PUBLIC_IP"
echo "   Bastion (public): $BASTION_PUBLIC_IP"

# Save configuration NOW so other scripts can use it immediately
echo ""
echo "💾 Saving deployment configuration..."
cat > .deployment-config << CONFIGEOF
# Auto-generated deployment configuration
# Created: $(date)
BASTION_IP=${BASTION_PUBLIC_IP}
WEB_IP=${WEB_PRIVATE_IP}
FLASK_IP=${FLASK_PRIVATE_IP}
WEB_PUBLIC_IP=${WEB_PUBLIC_IP}
ADMIN_USER=${ADMIN_USERNAME}
RESOURCE_GROUP=${RESOURCE_GROUP}
CONFIGEOF

echo "   ✅ Configuration saved to .deployment-config"
echo ""
echo "ℹ️  You can now run ./upload-website.sh or ./upload-admin.sh"
echo "   in another terminal if needed!"
echo ""

# --- 9. DEPLOY WEBSITE AND CONFIGURE NGINX ---
echo "🚀 Step 9: Deploying website and configuring services..."

# Wait for SSH to be available
echo "   Waiting for SSH to be ready..."
sleep 45

# Test SSH connectivity to bastion
echo "   Testing SSH connection to Bastion..."
ssh -A -o StrictHostKeyChecking=no -o ConnectTimeout=10 ${ADMIN_USERNAME}@${BASTION_PUBLIC_IP} "echo 'Bastion connection successful'"

if [ $? -ne 0 ]; then
  echo "   ⚠️  SSH connection failed. Waiting additional 30 seconds..."
  sleep 30
fi

# Update nginx config on Flask VM
echo "   Configuring Flask Backend VM..."
ssh -A -o StrictHostKeyChecking=no ${ADMIN_USERNAME}@${BASTION_PUBLIC_IP} << EOF
  echo "Connecting to Flask VM..."
  ssh -o StrictHostKeyChecking=no ${ADMIN_USERNAME}@${FLASK_PRIVATE_IP} << 'INNER_EOF'
    echo "Flask VM reached successfully"
    # Wait for Flask service to be ready
    sleep 10
    sudo systemctl status flask-app --no-pager || echo "Flask app starting..."
INNER_EOF
EOF

# Update nginx config on Web VM
echo "   Configuring Web Frontend VM..."
ssh -A -o StrictHostKeyChecking=no ${ADMIN_USERNAME}@${BASTION_PUBLIC_IP} << EOF
  echo "Connecting to Web VM..."
  ssh -o StrictHostKeyChecking=no ${ADMIN_USERNAME}@${WEB_PRIVATE_IP} << 'INNER_EOF'
    echo "Web VM reached successfully"
    # Update nginx config with Flask IP
    sudo sed -i 's|FLASK_IP_PLACEHOLDER|${FLASK_PRIVATE_IP}|g' /etc/nginx/sites-available/default
    sudo systemctl restart nginx
    echo "Nginx restarted successfully"
INNER_EOF
EOF

# Check if index.html exists locally
if [ -f "index.html" ]; then
  echo "   Uploading index.html to Web VM..."
  
  # Upload via SCP with ProxyJump
  scp -o StrictHostKeyChecking=no \
      -o ProxyJump=${ADMIN_USERNAME}@${BASTION_PUBLIC_IP} \
      index.html ${ADMIN_USERNAME}@${WEB_PRIVATE_IP}:/tmp/index.html
  
  if [ $? -eq 0 ]; then
    # Move to web root via SSH
    ssh -A -o StrictHostKeyChecking=no ${ADMIN_USERNAME}@${BASTION_PUBLIC_IP} << EOF
      ssh -o StrictHostKeyChecking=no ${ADMIN_USERNAME}@${WEB_PRIVATE_IP} << 'INNER_EOF'
        sudo mv /tmp/index.html /var/www/html/index.html
        sudo chown www-data:www-data /var/www/html/index.html
        echo "Website deployed successfully"
INNER_EOF
EOF
    echo "   ✅ Website uploaded successfully!"
  else
    echo "   ⚠️  Upload failed. You can upload manually (see instructions at end)"
  fi
else
  echo "   ⚠️  index.html not found in current directory"
  echo "   Continuing without uploading website..."
  echo "   You'll need to upload it manually (see instructions at end)"
fi

# --- 10. FINALIZE ---
echo ""
echo "=========================================="
echo "✨ DEPLOYMENT COMPLETE! ✨"
echo "=========================================="
echo ""

# Config already saved in Step 8
echo "📄 Configuration file: .deployment-config"
echo ""

echo "🌐 Access your website at:"
echo "   http://${WEB_PUBLIC_IP}"
echo ""
echo "🔐 SSH Access (via Bastion with agent forwarding):"
echo "   ssh -A ${ADMIN_USERNAME}@${BASTION_PUBLIC_IP}"
echo ""
echo "   From Bastion, connect to:"
echo "   - Web Frontend:  ssh ${ADMIN_USERNAME}@${WEB_PRIVATE_IP}"
echo "   - Flask Backend: ssh ${ADMIN_USERNAME}@${FLASK_PRIVATE_IP}"
echo ""
echo "🗄️  Database:"
echo "   Server: ${DB_SERVER_NAME}.postgres.database.azure.com"
echo "   Database: ${DB_NAME}"
echo ""
echo "📊 Check Flask Backend Health:"
echo "   ssh -A ${ADMIN_USERNAME}@${BASTION_PUBLIC_IP}"
echo "   ssh ${ADMIN_USERNAME}@${FLASK_PRIVATE_IP}"
echo "   curl http://localhost:5000/health"
echo ""
echo "🔧 If there were issues during deployment, run:"
echo "   ./fix-deployment.sh"
echo ""
echo "📤 To upload website and admin page:"
echo "   ./upload-website.sh"
echo "   ./upload-admin.sh"
echo ""
echo "🔍 View registrations:"
echo "   curl http://${WEB_PUBLIC_IP}/api/registrations"
echo ""
echo "🧹 Cleanup when done:"
echo "   az group delete --name ${RESOURCE_GROUP} --yes --no-wait"
echo ""
echo "=========================================="

# Cleanup temporary files
rm -f flask-config.yaml web-config.yaml

echo "🎉 Your magical Harry Potter webinar site deployment is complete!"