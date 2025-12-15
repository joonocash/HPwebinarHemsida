import os
from datetime import datetime
from flask import Flask, request, render_template_string
from flask_sqlalchemy import SQLAlchemy


app = Flask(__name__)

# Database configuration - uses SQLite by default, can be overridden with DATABASE_URL
app.config['SQLALCHEMY_DATABASE_URI'] = os.environ.get(
    'DATABASE_URL',
    'sqlite:///messages.db'
)
app.config['SQLALCHEMY_TRACK_MODIFICATIONS'] = False

db = SQLAlchemy(app)
class Message(db.Model):
    """Stores contact form submissions."""
    id = db.Column(db.Integer, primary_key=True)
    name = db.Column(db.String(100), nullable=False)
    email = db.Column(db.String(120), nullable=False)
    message = db.Column(db.Text, nullable=False)
    created_at = db.Column(db.DateTime, default=datetime.utcnow)

    def __repr__(self):
        return f'<Message from {self.name}>'

HOME_PAGE = """
<!DOCTYPE html>
<html>
<head>
    <title>Welcome</title>
    <style>
        body { font-family: Arial, sans-serif; max-width: 500px; margin: 50px auto; padding: 20px; text-align: center; }
        h1 { color: #333; }
        a { color: #007bff; text-decoration: none; font-size: 1.2em; margin: 0 10px; }
        a:hover { text-decoration: underline; }
    </style>
</head>
<body>
    <h1>Welcome</h1>
    <p>This is a simple Flask application with database persistence.</p>
    <p>
        <a href="/contact">Contact Us</a>
        <a href="/messages">View Messages</a>
    </p>
</body>
</html>
"""


CONTACT_FORM = """
<!DOCTYPE html>
<html>
<head>
    <title>Contact Us</title>
    <style>
        body { font-family: Arial, sans-serif; max-width: 500px; margin: 50px auto; padding: 20px; }
        h1 { color: #333; }
        label { display: block; margin-top: 15px; font-weight: bold; }
        input, textarea { width: 100%; padding: 8px; margin-top: 5px; box-sizing: border-box; }
        textarea { height: 100px; }
        button { margin-top: 20px; padding: 10px 20px; background: #007bff; color: white; border: none; cursor: pointer; }
        button:hover { background: #0056b3; }
    </style>
</head>
<body>
    <h1>Contact Us</h1>
    <form method="POST" action="/contact">
        <label for="name">Name:</label>
        <input type="text" id="name" name="name" required>
        <label for="email">Email:</label>
        <input type="email" id="email" name="email" required>
        <label for="message">Message:</label>
        <textarea id="message" name="message" required></textarea>
        <button type="submit">Send Message</button>
    </form>
</body>
</html>
"""

THANK_YOU = """
<!DOCTYPE html>
<html>
<head>
    <title>Thank You</title>
    <style>
        body { font-family: Arial, sans-serif; max-width: 500px; margin: 50px auto; padding: 20px; text-align: center; }
        h1 { color: #28a745; }
        a { color: #007bff; }
    </style>
</head>
<body>
    <h1>Thank You!</h1>
    <p>Thank you for contacting us, {{ name }}.</p>
    <p>We have received your message and will respond to {{ email }} soon.</p>
    <a href="/contact">Send another message</a>
</body>
</html>
"""
MESSAGES_PAGE = """
<!DOCTYPE html>
<html>
<head>
    <title>All Messages</title>
    <style>
        body { font-family: Arial, sans-serif; max-width: 700px; margin: 50px auto; padding: 20px; }
        h1 { color: #333; }
        .message { border: 1px solid #ddd; padding: 15px; margin: 15px 0; border-radius: 5px; }
        .message h3 { margin: 0 0 10px 0; color: #007bff; }
        .message p { margin: 5px 0; }
        .meta { color: #666; font-size: 0.9em; }
        a { color: #007bff; }
        .empty { color: #666; font-style: italic; }
    </style>
</head>
<body>
    <h1>All Messages</h1>
    <p><a href="/">Home</a> | <a href="/contact">Send a message</a></p>
    {% if messages %}
        {% for msg in messages %}
        <div class="message">
            <h3>{{ msg.name }}</h3>
            <p><strong>Email:</strong> {{ msg.email }}</p>
            <p>{{ msg.message }}</p>
            <p class="meta">Received: {{ msg.created_at.strftime('%Y-%m-%d %H:%M') }}</p>
        </div>
        {% endfor %}
    {% else %}
        <p class="empty">No messages yet. <a href="/contact">Send the first one!</a></p>
    {% endif %}
</body>
</html>
"""

# Create tables if they don't exist
with app.app_context():
    db.create_all()

@app.route("/")
def home():
    return render_template_string(HOME_PAGE)

@app.route("/contact", methods=["GET", "POST"])
def contact():
    if request.method == "POST":
        name = request.form.get("name")
        email = request.form.get("email")
        message_text = request.form.get("message")

        # Save to database
        new_message = Message(
            name=name,
            email=email,
            message=message_text
        )
        db.session.add(new_message)
        db.session.commit()

        print("\n" + "=" * 50)
        print("NEW CONTACT FORM SUBMISSION (saved to database)")
        print("=" * 50)
        print(f"Name:    {name}")
        print(f"Email:   {email}")
        print(f"Message: {message_text}")
        print("=" * 50 + "\n")

        return render_template_string(THANK_YOU, name=name, email=email)
    return render_template_string(CONTACT_FORM)

@app.route("/messages")
def messages():
    all_messages = Message.query.order_by(Message.created_at.desc()).all()
    return render_template_string(MESSAGES_PAGE, messages=all_messages)


if __name__ == "__main__":
    app.run(host="0.0.0.0", port=5001, debug=True)
