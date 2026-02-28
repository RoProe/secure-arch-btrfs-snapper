source "$HOME/.config/waybar/scripts/.imap"

python3 - <<EOF
import imaplib, os, sys

IMAP_SERVER = os.environ.get("IMAP_SERVER")
IMAP_USER   = os.environ.get("IMAP_USER")
IMAP_PASS   = os.environ.get("IMAP_PASS")

missing = [k for k, v in [("IMAP_SERVER", IMAP_SERVER), ("IMAP_USER", IMAP_USER), ("IMAP_PASS", IMAP_PASS)] if not v]
if missing:
    print("Missing env vars: " + ", ".join(missing), file=sys.stderr)
    sys.exit(1)

M = imaplib.IMAP4_SSL(IMAP_SERVER)
try:
    M.login(IMAP_USER, IMAP_PASS)

    status, mailboxes = M.list()
    if status == "OK" and mailboxes:
        for mbox in mailboxes:
            print(mbox.decode(errors="replace"))
finally:
    try:
        M.logout()
    except Exception:
        pass
EOF
