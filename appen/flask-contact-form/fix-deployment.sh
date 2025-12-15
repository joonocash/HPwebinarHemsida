#!/bin/bash

# ===================================================
# FIX FLASK APP - Debug and repair
# ===================================================

echo "=========================================="
echo "🔧 FIXING FLASK BACKEND"
echo "=========================================="

# Load configuration from file if it exists
if [ -f ".deployment-config" ]; then
  echo "📖 Loading configuration from .deployment-config..."
  source .deployment-config
  echo "   ✅ Configuration loaded"
  echo "   Bastion: $BASTION_IP"
  echo "   Flask VM: $FLASK_IP"
else
  echo "⚠️  No .deployment-config found. Using manual configuration..."
  echo ""
  echo "Please enter the IP addresses (or press Ctrl+C and run ultimate-deploy.sh first):"
  read -p "Bastion IP: " BASTION_IP
  read -p "Flask Private IP: " FLASK_IP
  ADMIN_USER="azureuser"
fi

echo "=========================================="
echo ""

# Ensure SSH agent is running
if [ -z "$SSH_AUTH_SOCK" ]; then
  eval $(ssh-agent -s)
fi

if [ -f ~/.ssh/id_rsa ]; then
  ssh-add ~/.ssh/id_rsa 2>/dev/null
elif [ -f ~/.ssh/id_ed25519 ]; then
  ssh-add ~/.ssh/id_ed25519 2>/dev/null
fi

echo "Connecting to Flask VM to diagnose issue..."
echo ""

ssh -A -o StrictHostKeyChecking=no ${ADMIN_USER}@${BASTION_IP} << 'EOF'
  ssh -o StrictHostKeyChecking=no azureuser@10.0.0.4 << 'INNER_EOF'
    echo "=== DIAGNOSING FLASK APP ==="
    echo ""
    
    cd /home/azureuser
    
    # Check if app.py exists
    echo "1. Checking if app.py exists..."
    if [ -f app.py ]; then
      echo "   ✅ app.py found"
    else
      echo "   ❌ app.py NOT found - this is the problem!"
      echo "   Creating app.py..."
      
      cat > app.py << 'PYEOF'
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
PYEOF
      
      echo "   ✅ app.py created"
    fi
    
    # Check requirements.txt
    echo ""
    echo "2. Checking requirements.txt..."
    if [ -f requirements.txt ]; then
      echo "   ✅ requirements.txt found"
    else
      echo "   Creating requirements.txt..."
      cat > requirements.txt << 'REQEOF'
flask
gunicorn
flask-sqlalchemy
flask-cors
psycopg2-binary
REQEOF
      echo "   ✅ requirements.txt created"
    fi
    
    # Check venv
    echo ""
    echo "3. Checking virtual environment..."
    if [ -d venv ]; then
      echo "   ✅ venv exists"
    else
      echo "   Creating venv..."
      python3 -m venv venv
    fi
    
    # Install dependencies
    echo ""
    echo "4. Installing dependencies..."
    source venv/bin/activate
    pip install -q flask gunicorn flask-sqlalchemy flask-cors psycopg2-binary
    echo "   ✅ Dependencies installed"
    
    # Test app manually
    echo ""
    echo "5. Testing app manually..."
    source venv/bin/activate
    timeout 5 python3 app.py &
    sleep 3
    curl -s http://localhost:5000/health && echo "" || echo "   ⚠️  App test failed"
    pkill -f "python3 app.py"
    
    # Check systemd service file
    echo ""
    echo "6. Checking systemd service..."
    if sudo test -f /etc/systemd/system/flask-app.service; then
      echo "   ✅ Service file exists"
      echo "   Current service configuration:"
      sudo cat /etc/systemd/system/flask-app.service | grep -E "ExecStart|Environment|WorkingDirectory"
    else
      echo "   ❌ Service file missing!"
    fi
    
    # Kill anything on port 5000
    echo ""
    echo "7. Cleaning up port 5000..."
    sudo fuser -k 5000/tcp 2>/dev/null || echo "   No process on port 5000"
    sleep 2
    
    # Restart service
    echo ""
    echo "8. Restarting Flask service..."
    sudo systemctl daemon-reload
    sudo systemctl restart flask-app
    sleep 5
    
    # Check service status
    echo ""
    echo "9. Service status:"
    sudo systemctl status flask-app --no-pager -l | head -20
    
    # Check logs
    echo ""
    echo "10. Recent logs:"
    sudo journalctl -u flask-app -n 20 --no-pager
    
    # Final health check
    echo ""
    echo "11. Final health check:"
    curl -s http://localhost:5000/health || echo "   ❌ Flask app still not responding"
    
    echo ""
    echo "=== DIAGNOSIS COMPLETE ==="
INNER_EOF
EOF

echo ""
echo "=========================================="
echo "Check the output above for issues"
echo "=========================================="
echo ""
echo "To manually check Flask logs:"
echo "  ssh -A ${ADMIN_USER}@${BASTION_IP}"
echo "  ssh ${ADMIN_USER}@${FLASK_IP}"
echo "  sudo journalctl -u flask-app -f"
echo ""