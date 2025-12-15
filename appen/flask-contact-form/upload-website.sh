#!/bin/bash

# ===================================================
# UPLOAD MAIN WEBSITE SCRIPT
# Uploads index.html to the web server
# ===================================================

echo "=========================================="
echo "📤 UPLOADING MAIN WEBSITE"
echo "=========================================="

# Load configuration from file if it exists
if [ -f ".deployment-config" ]; then
  echo "📖 Loading configuration from .deployment-config..."
  source .deployment-config
  echo "   ✅ Configuration loaded"
  echo "   Bastion: $BASTION_IP"
  echo "   Web VM: $WEB_IP"
  if [ -n "$WEB_PUBLIC_IP" ]; then
    echo "   Public IP: $WEB_PUBLIC_IP"
  fi
else
  echo "❌ ERROR: No .deployment-config found!"
  echo ""
  echo "Please run ./ultimate-deploy.sh first to create the configuration."
  exit 1
fi

# Set default admin user if not in config
if [ -z "$ADMIN_USER" ]; then
  ADMIN_USER="azureuser"
fi

echo "=========================================="
echo ""

# Check if index.html exists
if [ ! -f "index.html" ]; then
  echo "❌ ERROR: index.html not found in current directory!"
  echo "Please make sure index.html is in the same directory as this script."
  exit 1
fi

echo "✅ Found index.html"
echo ""

# Ensure SSH agent is running
echo "🔑 Setting up SSH agent..."
if [ -z "$SSH_AUTH_SOCK" ]; then
  eval $(ssh-agent -s)
fi

if [ -f ~/.ssh/id_rsa ]; then
  ssh-add ~/.ssh/id_rsa 2>/dev/null
  echo "   ✅ SSH key added"
elif [ -f ~/.ssh/id_ed25519 ]; then
  ssh-add ~/.ssh/id_ed25519 2>/dev/null
  echo "   ✅ SSH key added"
fi

echo ""
echo "Step 1: Uploading to Bastion..."
scp -o StrictHostKeyChecking=no index.html ${ADMIN_USER}@${BASTION_IP}:/tmp/

if [ $? -ne 0 ]; then
  echo "❌ Failed to upload to Bastion"
  exit 1
fi

echo "✅ Uploaded to Bastion"
echo ""

echo "Step 2: Deploying to Web Server..."
ssh -A -o StrictHostKeyChecking=no ${ADMIN_USER}@${BASTION_IP} << EOF
  # Copy to web server
  scp -o StrictHostKeyChecking=no /tmp/index.html ${ADMIN_USER}@${WEB_IP}:/tmp/index.html
  
  # Move to web root
  ssh -o StrictHostKeyChecking=no ${ADMIN_USER}@${WEB_IP} << 'WEB_EOF'
    sudo mv /tmp/index.html /var/www/html/index.html
    sudo chown www-data:www-data /var/www/html/index.html
    sudo chmod 644 /var/www/html/index.html
    echo "✅ Website deployed"
WEB_EOF
  
  # Clean up temp file on bastion
  rm -f /tmp/index.html
EOF

if [ $? -ne 0 ]; then
  echo "❌ Failed to deploy to Web Server"
  exit 1
fi

echo "✅ Deployed to Web Server"
echo ""
echo "=========================================="
echo "✨ MAIN WEBSITE UPLOADED SUCCESSFULLY!"
echo "=========================================="
echo ""
echo "🌐 Access your website at:"
if [ -n "$WEB_PUBLIC_IP" ]; then
  echo "   http://${WEB_PUBLIC_IP}"
else
  echo "   http://YOUR_WEB_PUBLIC_IP"
  echo "   (Check .deployment-config for IP)"
fi
echo ""
echo "=========================================="