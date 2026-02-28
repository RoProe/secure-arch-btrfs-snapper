#!/usr/bin/env python3
import imaplib, email, sys, os, json, html
from email.header import decode_header
from email.utils import parsedate_to_datetime
from datetime import timezone

IMAP_SERVER = os.environ['IMAP_SERVER']
IMAP_USER = os.environ['IMAP_USER']
IMAP_PASS = os.environ['IMAP_PASS']
MAILBOXES = os.environ['MAILBOXES'].split(',')

def decode(value):
    if not value:
        return ""
    parts = decode_header(value)
    s = ""
    for p, enc in parts:
        if isinstance(p, bytes):
            s += p.decode(enc or "utf-8", errors="ignore")
        else:
            s += p
    return s

all_unseen = []
try:
    M = imaplib.IMAP4_SSL(IMAP_SERVER)
    M.login(IMAP_USER, IMAP_PASS)

    for box in MAILBOXES:
        M.select(box)
        status,data = M.search(None, 'UNSEEN')
        uids = data[0].split()
        for uid in uids:
            status, msg_data = M.fetch(uid,'(BODY.PEEK[HEADER.FIELDS (SUBJECT FROM DATE)])')
            msg = email.message_from_bytes(msg_data[0][1])
            date = msg.get("Date")
            if date:
                date_dt = parsedate_to_datetime(date)
                if date_dt and date_dt.tzinfo is None:
                    date_dt = date_dt.replace(tzinfo=timezone.utc)
                else:
                    date_dt = date_dt.astimezone(timezone.utc)
            else:
                date_dt = None
            subject = decode(msg.get("Subject"))
            from_ = decode(msg.get("From"))
            all_unseen.append((date_dt, box, subject, from_))

    all_unseen.sort(key=lambda x: x[0] or 0, reverse=True)
    latest5 = all_unseen[:5]

    output = {
        "text": f"󰶍  {len(all_unseen)}",
        "tooltip": "\n".join([f" <b>{html.escape(subject)}</b>\n  {html.escape(from_)}\n  <small>{date_dt}</small>" for date_dt, box, subject, from_ in latest5])
    }

    print(json.dumps(output))
    M.logout()

except Exception as e:
    print(json.dumps({"text": "⚠", "tooltip": str(e)}))

