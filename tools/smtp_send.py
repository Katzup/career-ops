#!/usr/bin/env python3
"""
Send HTML email via SMTP (Gmail app password).

Usage:
    python3 tools/smtp_send.py --to addr --subject "..." --html "<p>...</p>"

Environment:
    SMTP_USER   sender address (default: rjkatz@gmail.com)
    SMTP_PASS   Gmail app password (16-char, no spaces)
"""
import argparse
import os
import smtplib
import sys
from email.mime.multipart import MIMEMultipart
from email.mime.text import MIMEText

SMTP_SERVER = "smtp.gmail.com"
SMTP_PORT = 587


def send(to: str, subject: str, html: str, text: str = "") -> None:
    user = os.environ.get("SMTP_USER", "rjkatz@gmail.com")
    password = os.environ.get("SMTP_PASS", "")
    if not password:
        sys.exit("SMTP_PASS environment variable is not set")

    msg = MIMEMultipart("alternative")
    msg["From"] = user
    msg["To"] = to
    msg["Subject"] = subject
    if text:
        msg.attach(MIMEText(text, "plain"))
    msg.attach(MIMEText(html, "html"))

    with smtplib.SMTP(SMTP_SERVER, SMTP_PORT) as server:
        server.ehlo()
        server.starttls()
        server.login(user, password)
        server.sendmail(user, to, msg.as_string())

    print(f"SENT: {subject} -> {to}")


if __name__ == "__main__":
    parser = argparse.ArgumentParser()
    parser.add_argument("--to", required=True)
    parser.add_argument("--subject", required=True)
    parser.add_argument("--html", required=True)
    parser.add_argument("--text", default="")
    args = parser.parse_args()
    send(args.to, args.subject, args.html, args.text)
