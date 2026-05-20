"""
Gmail API sender with attachment support.
Supports dry-run, draft, and send modes.
OAuth token stored in .secrets/ (gitignored).
"""
from __future__ import annotations

import base64
import json
import logging
import mimetypes
from email.message import EmailMessage
from pathlib import Path
from typing import Iterable

from google.auth.transport.requests import Request
from google.oauth2.credentials import Credentials
from google_auth_oauthlib.flow import InstalledAppFlow
from googleapiclient.discovery import build

SCOPES = ["https://www.googleapis.com/auth/gmail.send"]
SECRETS_DIR = Path(__file__).parent.parent / ".secrets"
TOKEN_PATH = SECRETS_DIR / "gmail_token.json"
CLIENT_SECRET_PATH = SECRETS_DIR / "google_oauth_client.json"

logging.basicConfig(
    format="%(asctime)s [%(levelname)s] %(message)s",
    level=logging.INFO,
)
log = logging.getLogger(__name__)


def _get_credentials() -> Credentials:
    creds = None
    if TOKEN_PATH.exists():
        creds = Credentials.from_authorized_user_file(str(TOKEN_PATH), SCOPES)
    if not creds or not creds.valid:
        if creds and creds.expired and creds.refresh_token:
            creds.refresh(Request())
        else:
            if not CLIENT_SECRET_PATH.exists():
                raise FileNotFoundError(
                    f"OAuth client secret not found at {CLIENT_SECRET_PATH}. "
                    "Download it from Google Cloud Console and place it there."
                )
            flow = InstalledAppFlow.from_client_secrets_file(
                str(CLIENT_SECRET_PATH), SCOPES
            )
            creds = flow.run_local_server(port=8080, open_browser=True)
            print("\n>>> If no browser opened, visit this URL to authorize:")
            print(flow.authorization_url()[0] if hasattr(flow, 'authorization_url') else "Re-run the script")
        TOKEN_PATH.write_text(creds.to_json())
        log.info("OAuth token saved to %s", TOKEN_PATH)
    return creds


def _build_mime_message(
    sender: str,
    to: str,
    subject: str,
    body: str,
    attachments: Iterable[str] = (),
    cc: str | None = None,
    bcc: str | None = None,
) -> EmailMessage:
    msg = EmailMessage()
    msg["From"] = sender
    msg["To"] = to
    msg["Subject"] = subject
    if cc:
        msg["Cc"] = cc
    if bcc:
        msg["Bcc"] = bcc
    is_html = body.lstrip().startswith("<")
    if is_html:
        msg.set_content("Please enable HTML to view this email.")
        msg.add_alternative(body, subtype="html")
    else:
        msg.set_content(body)

    for file_path in attachments:
        path = Path(file_path).expanduser().resolve()
        if not path.exists():
            raise FileNotFoundError(f"Attachment not found: {path}")
        ctype, encoding = mimetypes.guess_type(str(path))
        if ctype is None or encoding is not None:
            ctype = "application/octet-stream"
        maintype, subtype = ctype.split("/", 1)
        with path.open("rb") as f:
            msg.add_attachment(
                f.read(),
                maintype=maintype,
                subtype=subtype,
                filename=path.name,
            )
        log.info("Attached: %s (%s/%s)", path.name, maintype, subtype)

    return msg


def _encode(msg: EmailMessage) -> dict:
    return {"raw": base64.urlsafe_b64encode(msg.as_bytes()).decode("utf-8")}


def send_email(
    sender: str,
    to: str,
    subject: str,
    body: str,
    attachments: Iterable[str] = (),
    cc: str | None = None,
    bcc: str | None = None,
    mode: str = "draft",
) -> dict:
    """
    Send or draft an email with optional attachments.

    mode:
      dry-run  — validate inputs and log, do not call Gmail API
      draft    — create a Gmail draft (default, safe)
      send     — send immediately
    """
    attachment_list = list(attachments)

    # Validate attachment paths before touching the API
    for path in attachment_list:
        resolved = Path(path).expanduser().resolve()
        if not resolved.exists():
            raise FileNotFoundError(f"Attachment not found: {resolved}")

    log.info(
        "MODE=%s | to=%s | subject=%s | attachments=%s",
        mode,
        to,
        subject,
        [Path(a).name for a in attachment_list],
    )

    if mode == "dry-run":
        log.info("DRY RUN — no Gmail API call made.")
        return {"mode": "dry-run", "to": to, "subject": subject,
                "attachments": [Path(a).name for a in attachment_list]}

    msg = _build_mime_message(
        sender=sender,
        to=to,
        subject=subject,
        body=body,
        attachments=attachment_list,
        cc=cc,
        bcc=bcc,
    )
    encoded = _encode(msg)
    creds = _get_credentials()
    service = build("gmail", "v1", credentials=creds)

    if mode == "send":
        result = service.users().messages().send(userId="me", body=encoded).execute()
        log.info("SENT | message_id=%s", result.get("id"))
        return result
    else:  # draft
        result = service.users().drafts().create(
            userId="me", body={"message": encoded}
        ).execute()
        log.info("DRAFT CREATED | draft_id=%s", result.get("id"))
        return result
