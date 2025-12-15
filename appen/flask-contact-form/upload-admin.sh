#!/bin/bash

# ===================================================
# UPLOAD ADMIN PAGE SCRIPT
# Uploads admin.html to the web server
# ===================================================

echo "=========================================="
echo "📤 UPLOADING ADMIN PAGE"
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
  echo ""
  echo "Or create .deployment-config manually with:"
  echo "  BASTION_IP=your_bastion_ip"
  echo "  WEB_IP=your_web_private_ip"
  echo "  ADMIN_USER=azureuser"
  echo "  WEB_PUBLIC_IP=your_web_public_ip"
  exit 1
fi

# Set default admin user if not in config
if [ -z "$ADMIN_USER" ]; then
  ADMIN_USER="azureuser"
fi

echo "=========================================="
echo ""

# Check if admin.html exists
if [ ! -f "admin.html" ]; then
  echo "❌ ERROR: admin.html not found in current directory!"
  echo "Please make sure admin.html is in the same directory as this script."
  exit 1
fi

echo "✅ Found admin.html"
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
scp -o StrictHostKeyChecking=no admin.html ${ADMIN_USER}@${BASTION_IP}:/tmp/

if [ $? -ne 0 ]; then
  echo "❌ Failed to upload to Bastion"
  exit 1
fi

echo "✅ Uploaded to Bastion"
echo ""

echo "Step 2: Deploying to Web Server..."
ssh -A -o StrictHostKeyChecking=no ${ADMIN_USER}@${BASTION_IP} << 'EOF'
  # Copy to web server
  scp -o StrictHostKeyChecking=no /tmp/admin.html azureuser@10.0.0.5:/tmp/
  
  # Move to web root
  ssh -o StrictHostKeyChecking=no azureuser@10.0.0.5 'sudo mv /tmp/admin.html /var/www/html/admin.html && sudo chown www-data:www-data /var/www/html/admin.html && sudo chmod 644 /var/www/html/admin.html'
  
  # Clean up
  rm -f /tmp/admin.html
EOF

if [ $? -ne 0 ]; then
  echo "❌ Failed to deploy to Web Server"
  exit 1
fi

echo "✅ Deployed to Web Server"
echo ""
echo "=========================================="
echo "✨ ADMIN PAGE UPLOADED SUCCESSFULLY!"
echo "=========================================="
echo ""
echo "🌐 Access your admin page at:"
if [ -n "$WEB_PUBLIC_IP" ]; then
  echo "   http://${WEB_PUBLIC_IP}/admin.html"
else
  echo "   http://YOUR_WEB_PUBLIC_IP/admin.html"
  echo "   (Check .deployment-config or Azure portal for IP)"
fi
echo ""
echo "=========================================="