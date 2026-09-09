#!/bin/bash
#
# install.sh - set up send-secure-mail on Linux or macOS.
#
# Run without options and the script asks for everything interactively:
#
#   sudo ./install.sh
#
# Anything can also be passed as an option; only what is missing gets asked:
#
#   sudo ./install.sh --gmail-user YOUR.NAME@gmail.com \
#                     --recipient you@example.org \
#                     --with-msmtp
#
# Creates:
#   /usr/local/bin/send-secure-mail
#   /etc/send-secure-mail/config.ini
#   /etc/send-secure-mail/recipient.asc      (recipient's public key)
#   /etc/msmtprc                             (msmtp transport)
#   /etc/send-secure-mail/smtp-password      (direct SMTP transport)
#
set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
CONF_DIR="/etc/send-secure-mail"
BIN_DIR="/usr/local/bin"
PROG="send-secure-mail"
APPPW_URL="https://myaccount.google.com/apppasswords"
SEC_URL="https://myaccount.google.com/security"
OS="$(uname -s)"

GMAIL_USER=""
RECIPIENT=""
KEY_FILE=""
SENDER_NAME=""
WITH_MSMTP=""       # empty = not decided yet
INSTALL_TIMER=""
HIDE_SUBJECT=""
ASSUME_YES=0
PASSWORD_FILE=""
SKIP_PACKAGES=0

red()  { printf '\033[31m%s\033[0m\n' "$*" >&2; }
grn()  { printf '\033[32m%s\033[0m\n' "$*"; }
bold() { printf '\033[1m%s\033[0m\n' "$*"; }
die()  { red "ERROR: $*"; exit 1; }

TMPFILES=()
cleanup() { [ "${#TMPFILES[@]}" -eq 0 ] || rm -f "${TMPFILES[@]}"; }
trap cleanup EXIT
# tmpfile VARNAME -> create a temp file, put its path in VARNAME, remove it
# on exit. Sets a variable rather than printing, so that the caller does not
# have to use a subshell (which would lose the TMPFILES entry).
tmpfile() {
    local __var="$1" __f
    __f="$(mktemp)" || die "Could not create a temporary file."
    TMPFILES+=("$__f")
    printf -v "$__var" '%s' "$__f"
}

usage() {
    cat <<'USAGE'
send-secure-mail installer (Linux and macOS)

Run without options to be asked for everything interactively:

  sudo ./install.sh

Options (whatever is given will not be asked for):

  --gmail-user ADDRESS     Gmail account used as the sender
  --recipient ADDRESS      recipient address (any OpenPGP mailbox)
  --key FILE               recipient's public PGP key (.asc)
                           default: publickey*.asc next to this script
  --sender-name NAME       display name of the sender
  --with-msmtp             set up msmtp as the sendmail replacement
                           (recommended if no MTA is installed)
  --no-msmtp               no MTA; the script speaks SMTP itself
  --password-file FILE     read the Gmail app password from this file
                           (or use the SSM_SMTP_PASSWORD variable)
  --show-subject           keep the subject in the plaintext header; the
                           default is an encrypted subject
  --install-timer          install a systemd timer for daily log mails
  --no-timer               do not install a timer
  --skip-packages          do not install any packages
  -y, --yes                no questions (everything needed must be given as
                           an option or via SSM_SMTP_PASSWORD)
  -h, --help               this help

Examples:
  sudo ./install.sh
  sudo ./install.sh --gmail-user your.name@gmail.com \
                    --recipient you@example.org --with-msmtp
  SSM_SMTP_PASSWORD=abcdefghijklmnop sudo -E ./install.sh -y \
                    --gmail-user your.name@gmail.com --recipient you@example.org \
                    --with-msmtp --no-timer
USAGE
}

while [ $# -gt 0 ]; do
    case "$1" in
        --gmail-user)    GMAIL_USER="${2:?}"; shift 2 ;;
        --recipient)     RECIPIENT="${2:?}"; shift 2 ;;
        --key)           KEY_FILE="${2:?}"; shift 2 ;;
        --sender-name)   SENDER_NAME="${2:?}"; shift 2 ;;
        --password-file) PASSWORD_FILE="${2:?}"; shift 2 ;;
        --with-msmtp)    WITH_MSMTP=1; shift ;;
        --no-msmtp)      WITH_MSMTP=0; shift ;;
        --hide-subject)  HIDE_SUBJECT=1; shift ;;
        --show-subject)  HIDE_SUBJECT=0; shift ;;
        --install-timer) INSTALL_TIMER=1; shift ;;
        --no-timer)      INSTALL_TIMER=0; shift ;;
        --skip-packages) SKIP_PACKAGES=1; shift ;;
        -y|--yes)        ASSUME_YES=1; shift ;;
        -h|--help)       usage; exit 0 ;;
        *) usage; die "Unknown option: $1" ;;
    esac
done

[ "$(id -u)" -eq 0 ] || die "Please run with sudo/root."

INTERACTIVE=0
if [ -t 0 ] && [ "$ASSUME_YES" -eq 0 ]; then
    INTERACTIVE=1
fi

HAS_SYSTEMD=0
if command -v systemctl >/dev/null 2>&1 && [ -d /run/systemd/system ]; then
    HAS_SYSTEMD=1
fi

# --------------------------------------------------------------- helpers ---
# ask VARNAME "question" ["default"]
ask() {
    local __var="$1" __q="$2" __def="${3:-}" __ans=""
    if [ -n "$__def" ]; then
        read -r -p "  $__q [$__def]: " __ans || die "Input aborted."
        [ -n "$__ans" ] || __ans="$__def"
    else
        read -r -p "  $__q: " __ans || die "Input aborted."
    fi
    printf -v "$__var" '%s' "$__ans"
}

# ask_yn VARNAME "question" y|n   -> sets VARNAME to 1 or 0
ask_yn() {
    local __var="$1" __q="$2" __def="${3:-y}" __ans="" __hint="[Y/n]"
    [ "$__def" = "n" ] && __hint="[y/N]"
    while :; do
        read -r -p "  $__q $__hint " __ans || die "Input aborted."
        [ -n "$__ans" ] || __ans="$__def"
        case "$__ans" in
            y|Y|yes|Yes|j|J) printf -v "$__var" '%s' 1; return ;;
            n|N|no|No)       printf -v "$__var" '%s' 0; return ;;
            *) echo "    Please answer y or n." ;;
        esac
    done
}

is_email() {
    printf '%s' "${1:-}" \
        | grep -qE '^[^@[:space:]]+@[^@[:space:]]+\.[^@[:space:]]+$'
}

need_interactive() {
    [ "$INTERACTIVE" -eq 1 ] || die "$1 is missing and there is no interactive \
input available - please pass it as an option (see --help)."
}

tmpfile GPG_ERR

# Print the colon-format listing of the keys in a file, empty if it holds
# none. --show-keys is a GnuPG 2.2.8 command; 2.1.x needs the import form.
show_keys() {
    gpg --batch --with-colons --show-keys "$1" 2>"$GPG_ERR" \
    || gpg --batch --with-colons --import-options show-only \
           --import "$1" 2>"$GPG_ERR"
}

# ------------------------------------------------------------- questions ---
if [ "$INTERACTIVE" -eq 1 ]; then
    bold "=== send-secure-mail setup ==="
    echo "Press Enter to accept the value in square brackets."
    echo
fi

# 1) sender -----------------------------------------------------------------
while ! is_email "$GMAIL_USER"; do
    need_interactive "--gmail-user"
    [ -z "$GMAIL_USER" ] || red "  That does not look like an address."
    ask GMAIL_USER "Gmail address used as the sender"
done

if [ -z "$SENDER_NAME" ] && [ "$INTERACTIVE" -eq 1 ]; then
    ask SENDER_NAME "Display name of the sender" "$(hostname)"
fi

# 2) recipient --------------------------------------------------------------
while ! is_email "$RECIPIENT"; do
    need_interactive "--recipient"
    [ -z "$RECIPIENT" ] || red "  That does not look like an address."
    ask RECIPIENT "Recipient address (Proton, mailbox.org, ... )"
done

# 3) key file ---------------------------------------------------------------
if [ -z "$KEY_FILE" ]; then
    # shellcheck disable=SC2012
    KEY_FILE="$(ls -1 "$SCRIPT_DIR"/publickey*.asc "$SCRIPT_DIR"/*.asc \
                2>/dev/null | head -n1 || true)"
    # An *.asc lying here need not actually hold a key - a common mishap is
    # `gpg --locate-keys ADDR > recipient.asc`, which writes a listing, not
    # a key. Drop such a file so the lookup below can still offer to help.
    if [ -n "$KEY_FILE" ] && [ -z "$(show_keys "$KEY_FILE" || true)" ]; then
        red "  $KEY_FILE holds no OpenPGP key - ignoring it."
        sed 's/^/    /' "$GPG_ERR" >&2
        KEY_FILE=""
    fi
fi

# No key next to the installer - offer to fetch it from the recipient's
# provider over WKD (how Proton Mail, mailbox.org and others publish keys).
if [ -z "$KEY_FILE" ] && [ "$INTERACTIVE" -eq 1 ] \
   && command -v gpg >/dev/null 2>&1; then
    echo
    echo "  No public key file was found next to the installer."
    echo "  It can be looked up automatically in the recipient's Web Key"
    echo "  Directory, or on the keyserver keys.openpgp.org."
    ask_yn TRY_FETCH "Look up the public key online?" y
    if [ "$TRY_FETCH" -eq 1 ]; then
        ask FETCH_ADDR "Fetch the key for which address?" "$RECIPIENT"
        tmpfile FETCH_ERR
        tmpfile FETCH_OUT
        echo "  Looking up $FETCH_ADDR ..."
        # --locate-keys fetches and imports; it prints a listing, not the
        # key itself, so the key is exported afterwards.
        if gpg --batch --yes \
               --auto-key-locate local,wkd,keyserver \
               --keyserver hkps://keys.openpgp.org \
               --locate-keys "$FETCH_ADDR" >/dev/null 2>"$FETCH_ERR" \
           && gpg --batch --yes --armor --export "$FETCH_ADDR" \
                  > "$FETCH_OUT" 2>>"$FETCH_ERR" \
           && [ -s "$FETCH_OUT" ]; then
            KEY_FILE="$FETCH_OUT"
            grn "  Found a key for $FETCH_ADDR."
            echo "  Check its fingerprint below before continuing."
        else
            red "  No key could be fetched for $FETCH_ADDR - gpg said:"
            sed 's/^/    /' "$FETCH_ERR" >&2
            echo "  Falling back to a local file."
        fi
    fi
fi

while [ -z "$KEY_FILE" ] || [ ! -f "$KEY_FILE" ]; do
    need_interactive "--key (public key)"
    [ -z "$KEY_FILE" ] || red "  File not found: $KEY_FILE"
    echo "  Export it from the recipient's provider (Proton Mail:"
    echo "  Settings > Encryption and keys > Export), or fetch it with"
    echo "  gpg --locate-keys ADDRESS && gpg --armor --export ADDRESS > recipient.asc"
    ask KEY_FILE "Path to the public key (.asc)"
done

# 4) transport --------------------------------------------------------------
if [ -z "$WITH_MSMTP" ]; then
    if [ -x /usr/sbin/sendmail ] || [ -x /usr/lib/sendmail ]; then
        DEF_MSMTP=n     # an MTA is already present
    else
        DEF_MSMTP=y
    fi
    if [ "$INTERACTIVE" -eq 1 ]; then
        echo
        echo "  Delivery path:"
        echo "    y = set up msmtp as sendmail (other programs on this"
        echo "        machine can then send mail through Gmail too)"
        echo "    n = no MTA, the script speaks SMTP with Gmail itself"
        [ "$DEF_MSMTP" = "n" ] && echo "    (a sendmail binary is already present)"
        ask_yn WITH_MSMTP "Set up msmtp?" "$DEF_MSMTP"
    else
        WITH_MSMTP=$([ "$DEF_MSMTP" = "y" ] && echo 1 || echo 0)
    fi
fi

# 5) subject: always encrypted unless --show-subject was given --------------
[ -n "$HIDE_SUBJECT" ] || HIDE_SUBJECT=1

# 6) timer ------------------------------------------------------------------
if [ -z "$INSTALL_TIMER" ]; then
    if [ "$HAS_SYSTEMD" -eq 0 ] || [ ! -d "$SCRIPT_DIR/systemd" ]; then
        INSTALL_TIMER=0
    elif [ "$INTERACTIVE" -eq 1 ]; then
        echo
        ask_yn INSTALL_TIMER \
            "Install a systemd timer for a daily journal mail?" n
    else
        INSTALL_TIMER=0
    fi
fi

# -------------------------------------------------------------- packages ---
pkg_manager() {
    local pm
    for pm in apt-get dnf yum zypper pacman apk brew; do
        command -v "$pm" >/dev/null 2>&1 && { printf '%s' "$pm"; return; }
    done
}

bold "==> Checking dependencies"
MISSING=""
command -v gpg     >/dev/null 2>&1 || MISSING="$MISSING gnupg"
command -v python3 >/dev/null 2>&1 || MISSING="$MISSING python3"
if [ "$WITH_MSMTP" -eq 1 ] && ! command -v msmtp >/dev/null 2>&1; then
    MISSING="$MISSING msmtp"
fi

if [ -z "$MISSING" ]; then
    echo "  everything needed is present."
elif [ "$SKIP_PACKAGES" -eq 1 ]; then
    die "Missing:$MISSING (--skip-packages was given)."
else
    PM="$(pkg_manager)"
    PKGS=""
    for m in $MISSING; do
        case "$m:$PM" in
            gnupg:dnf|gnupg:yum)  PKGS="$PKGS gnupg2" ;;
            gnupg:*)              PKGS="$PKGS gnupg" ;;
            python3:pacman)       PKGS="$PKGS python" ;;
            python3:*)            PKGS="$PKGS python3" ;;
            msmtp:apt-get|msmtp:pacman) PKGS="$PKGS msmtp msmtp-mta" ;;
            msmtp:*)              PKGS="$PKGS msmtp" ;;
        esac
    done
    echo "  installing:$PKGS"
    # shellcheck disable=SC2086
    case "$PM" in
        apt-get) export DEBIAN_FRONTEND=noninteractive
                 apt-get update -qq && apt-get install -y -qq $PKGS ;;
        dnf)     dnf install -y $PKGS ;;
        yum)     yum install -y $PKGS ;;
        zypper)  zypper --non-interactive install $PKGS ;;
        pacman)  pacman -Sy --noconfirm $PKGS ;;
        apk)     apk add --no-cache $PKGS ;;
        brew)    die "Homebrew refuses to run as root. Please run this first
without sudo:
    brew install$PKGS
then start this installer again." ;;
        *)       die "No known package manager found. Please install
manually:$PKGS" ;;
    esac
fi

# ------------------------------------------------------------- check key ---
bold "==> Checking the recipient key"
KEYINFO="$(show_keys "$KEY_FILE" || true)"
if [ -z "$KEYINFO" ]; then
    red "  gpg could not read $KEY_FILE - it said:"
    sed 's/^/    /' "$GPG_ERR" >&2
    red "  gpg version: $(gpg --version 2>/dev/null | head -n1)"
    die "No PGP key could be read from $KEY_FILE."
fi

FPR="$(awk -F: '/^fpr:/ {print $10; exit}' <<<"$KEYINFO")"
[ -n "$FPR" ] || die "No fingerprint found in $KEY_FILE."
UIDS="$(awk -F: '/^uid:/ {print $10}' <<<"$KEYINFO")"

echo "  File:        $KEY_FILE"
echo "  Fingerprint: $FPR"
echo "  Identity:    ${UIDS:-(none)}"

if ! printf '%s\n' "$UIDS" | grep -qiF "$RECIPIENT"; then
    red "  Warning: '$RECIPIENT' does not appear in the key's user IDs."
    if [ "$INTERACTIVE" -eq 1 ]; then
        ask_yn PROCEED "Continue anyway?" n
        [ "$PROCEED" -eq 1 ] || die "Aborted."
    fi
fi

if [ "$INTERACTIVE" -eq 1 ]; then
    echo
    echo "  Compare this fingerprint with the one the recipient publishes"
    echo "  (Proton Mail: Settings > Encryption and keys) for $RECIPIENT."
    ask_yn PROCEED "Does the fingerprint match?" n
    [ "$PROCEED" -eq 1 ] || die "Aborted - fingerprint not confirmed."
fi

# -------------------------------------------------------------- password ---
GMAIL_PASSWORD=""
if [ -n "${SSM_SMTP_PASSWORD:-}" ]; then
    GMAIL_PASSWORD="$SSM_SMTP_PASSWORD"
elif [ -n "$PASSWORD_FILE" ]; then
    [ -f "$PASSWORD_FILE" ] || die "Password file not found: $PASSWORD_FILE"
    GMAIL_PASSWORD="$(head -n1 "$PASSWORD_FILE" | tr -d '\r\n')"
else
    need_interactive "Gmail app password (--password-file or SSM_SMTP_PASSWORD)"
    bold "==> Gmail app password"
    echo "  Your normal Google password will not work. Google requires a"
    echo "  dedicated app password for SMTP (16 characters)."
    echo
    echo "  Create one here:"
    grn  "    $APPPW_URL"
    echo "  App: \"Mail\", device: \"Other\" -> e.g. \"$(hostname)\"."
    echo
    echo "  If that page does not open or stays empty, 2-step verification"
    echo "  is not enabled yet. Enable it first at:"
    echo "    $SEC_URL"
    echo
    echo "  Input stays hidden. Spaces do not matter."
    while :; do
        read -r -s -p "  App password for $GMAIL_USER: " GMAIL_PASSWORD \
            || die "Input aborted."
        echo
        read -r -s -p "  Repeat to confirm:            " PW2 \
            || die "Input aborted."
        echo
        GMAIL_PASSWORD="$(printf '%s' "$GMAIL_PASSWORD" | tr -d '[:space:]')"
        PW2="$(printf '%s' "$PW2" | tr -d '[:space:]')"
        if [ -z "$GMAIL_PASSWORD" ]; then
            red "  Empty - please try again."
            continue
        fi
        if [ "$GMAIL_PASSWORD" != "$PW2" ]; then
            red "  The two entries do not match - please try again."
            continue
        fi
        if ! printf '%s' "$GMAIL_PASSWORD" | grep -qE '^[a-z]{16}$'; then
            red "  Note: app passwords consist of 16 lowercase letters."
            ask_yn PROCEED "Use this input anyway?" n
            [ "$PROCEED" -eq 1 ] || continue
        fi
        unset PW2
        break
    done
fi
GMAIL_PASSWORD="$(printf '%s' "$GMAIL_PASSWORD" | tr -d '[:space:]')"
[ -n "$GMAIL_PASSWORD" ] || die "No password given."

# --------------------------------------------------------------- summary ---
if [ "$INTERACTIVE" -eq 1 ]; then
    echo
    bold "==> Summary"
    echo "  Sender:       $GMAIL_USER ${SENDER_NAME:+($SENDER_NAME)}"
    echo "  Recipient:    $RECIPIENT"
    echo "  Key:          $KEY_FILE"
    echo "  Fingerprint:  $FPR"
    echo "  Password:     set (${#GMAIL_PASSWORD} characters)"
    echo "  Transport:    $([ "$WITH_MSMTP" -eq 1 ] \
                            && echo 'sendmail via msmtp' || echo 'direct SMTP')"
    echo "  Subject:      $([ "$HIDE_SUBJECT" -eq 1 ] \
                            && echo 'encrypted' || echo 'in the clear')"
    echo "  Timer:        $([ "$INSTALL_TIMER" -eq 1 ] && echo 'yes' || echo 'no')"
    echo
    ask_yn PROCEED "Install with these settings?" y
    [ "$PROCEED" -eq 1 ] || die "Aborted."
fi

# ---------------------------------------------------------- installation ---
bold "==> Installing files"
[ -f "$SCRIPT_DIR/$PROG" ] || die "$PROG not found next to install.sh."
install -d -m 0755 "$CONF_DIR"
install -m 0755 "$SCRIPT_DIR/$PROG" "$BIN_DIR/$PROG"
install -m 0644 "$KEY_FILE" "$CONF_DIR/recipient.asc"
echo "  $BIN_DIR/$PROG"
echo "  $CONF_DIR/recipient.asc"

SENDMAIL_PATH="/usr/sbin/sendmail"
if [ "$WITH_MSMTP" -eq 1 ]; then
    TRANSPORT="sendmail"
    PWFILE=""
    # msmtp-mta provides /usr/sbin/sendmail; otherwise use msmtp directly.
    [ -x /usr/sbin/sendmail ] || SENDMAIL_PATH="$(command -v msmtp)"
    if [ -f /etc/msmtprc ]; then
        cp -a /etc/msmtprc "/etc/msmtprc.bak.$(date +%Y%m%d%H%M%S)"
        echo "  existing /etc/msmtprc backed up"
    fi
    TRUST_FILE=/etc/ssl/certs/ca-certificates.crt
    [ -f "$TRUST_FILE" ] || TRUST_FILE=/etc/pki/tls/certs/ca-bundle.crt
    [ -f "$TRUST_FILE" ] || TRUST_FILE=/etc/ssl/cert.pem
    umask 077
    cat > /etc/msmtprc <<MSMTP
# generated by send-secure-mail/install.sh
defaults
auth            on
tls             on
tls_trust_file  $TRUST_FILE
syslog          LOG_MAIL

account         gmail
host            smtp.gmail.com
port            587
from            $GMAIL_USER
user            $GMAIL_USER
password        $GMAIL_PASSWORD

account default : gmail
MSMTP
    chown root:root /etc/msmtprc 2>/dev/null || chown root /etc/msmtprc
    chmod 0600 /etc/msmtprc
    echo "  /etc/msmtprc (0600, root only)"
else
    TRANSPORT="smtp"
    PWFILE="$CONF_DIR/smtp-password"
    umask 077
    printf '%s\n' "$GMAIL_PASSWORD" > "$PWFILE"
    chown root:root "$PWFILE" 2>/dev/null || chown root "$PWFILE"
    chmod 0600 "$PWFILE"
    echo "  $PWFILE (0600, root only)"
fi
umask 022
unset GMAIL_PASSWORD

if [ -f "$CONF_DIR/config.ini" ]; then
    cp -a "$CONF_DIR/config.ini" "$CONF_DIR/config.ini.bak.$(date +%Y%m%d%H%M%S)"
fi
cat > "$CONF_DIR/config.ini" <<CONF
# send-secure-mail - generated by install.sh
[send-secure-mail]

# --- recipient ---
recipient             = $RECIPIENT
recipient_key         = $CONF_DIR/recipient.asc
recipient_fingerprint = $FPR
verify_fingerprint    = yes

# --- sender (Gmail) ---
sender      = $GMAIL_USER
sender_name = $SENDER_NAME

# --- delivery: sendmail (msmtp/postfix) or smtp (direct) ---
transport          = $TRANSPORT
sendmail_path      = $SENDMAIL_PATH
smtp_host          = smtp.gmail.com
smtp_port          = 587
smtp_user          = $GMAIL_USER
smtp_password_file = $PWFILE
smtp_starttls      = yes

# --- behaviour ---
# hide_subject=yes (default): only "..." goes out in the clear, the real
# subject travels inside the encrypted part.
hide_subject         = $([ "$HIDE_SUBJECT" -eq 1 ] && echo yes || echo no)
# What goes out in the clear instead of the real subject. Visible to Gmail,
# so keep it constant - e.g. a tag like "WG" to filter on.
hidden_subject       = ...
subject_prefix       =
gzip_attachments     = yes
max_attachment_bytes = 5242880

# --- optional: sign with your own key (fingerprint of a local secret key) ---
gpg_path             = gpg
sign_key             =
sign_passphrase_file =
CONF
chmod 0644 "$CONF_DIR/config.ini"
echo "  $CONF_DIR/config.ini"

# ----------------------------------------------------------------- timer ---
if [ "$INSTALL_TIMER" -eq 1 ]; then
    bold "==> Installing the systemd timer"
    install -m 0644 "$SCRIPT_DIR/systemd/send-secure-mail-logs.service" \
                    /etc/systemd/system/
    install -m 0644 "$SCRIPT_DIR/systemd/send-secure-mail-logs.timer" \
                    /etc/systemd/system/
    systemctl daemon-reload
    systemctl enable --now send-secure-mail-logs.timer
    echo "  daily delivery active (systemctl list-timers)"
fi

# ------------------------------------------------------------- test mail ---
grn ""
grn "Installation complete."
echo

if [ "$INTERACTIVE" -eq 1 ]; then
    ask_yn DO_TEST "Send an encrypted test mail to $RECIPIENT now?" y
    if [ "$DO_TEST" -eq 1 ]; then
        echo
        if "$BIN_DIR/$PROG" --test; then
            grn "Test mail sent - check the recipient inbox."
            echo "If you can read the text there, encryption works."
        else
            red "Delivery failed - see the message above."
            echo "To fix the credentials: sudo $0   (asks again)"
            [ "$WITH_MSMTP" -eq 1 ] && [ "$HAS_SYSTEMD" -eq 1 ] \
                && echo "msmtp log: journalctl -t msmtp -n 20"
            exit 1
        fi
    fi
fi

echo
echo "From here, for example:"
echo "  sudo $PROG -s 'Syslog' --attach /var/log/syslog"
if [ "$HAS_SYSTEMD" -eq 1 ]; then
    echo "  sudo journalctl -p err -S -1d | sudo $PROG -s 'Errors'"
    echo "  sudo $PROG --journal --journal-priority err"
elif [ "$OS" = "Darwin" ]; then
    echo "  sudo log show --last 1d --style compact | sudo $PROG -s 'System log'"
fi
echo
echo "Config and password belong to root, so run this with sudo, from a root"
if [ "$HAS_SYSTEMD" -eq 1 ]; then
    echo "cron job, or from the systemd timer."
else
    echo "cron job, or (on macOS) from launchd."
fi
