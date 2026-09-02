#!/bin/bash
set -euo pipefail

if [[ $# -ne 1 || "$1" == -* || "$1" =~ [[:space:]] ]]; then
  echo "Usage: $0 WINDOWS_USER@WINDOWS_IP" >&2
  exit 2
fi

remote_target="$1"
script_directory="$(cd "$(dirname "$0")" && pwd)"
project_directory="$(cd "$script_directory/.." && pwd)"
temporary_directory="$(mktemp -d)"
archive_path="$temporary_directory/local-receipt-printer-deploy.zip"
control_socket="$temporary_directory/ssh-control"

cleanup() {
  ssh -o ControlPath="$control_socket" -O exit "$remote_target" >/dev/null 2>&1 || true
  find "$temporary_directory" -depth -delete 2>/dev/null || true
}
trap cleanup EXIT

echo "Packaging Local Receipt Printer..."
ditto -c -k --keepParent --norsrc "$project_directory" "$archive_path"

echo "Connecting to $remote_target (the Windows account password may be requested once)..."
ssh -o ControlMaster=yes -o ControlPath="$control_socket" -o ControlPersist=120 -N -f "$remote_target"

echo "Copying installer and application..."
scp -o ControlPath="$control_socket" \
  "$archive_path" \
  "$script_directory/install-windows-remote.ps1" \
  "$remote_target:"

echo "Running the Windows installer..."
ssh -t -o ControlPath="$control_socket" "$remote_target" \
  'powershell.exe -NoLogo -NoProfile -ExecutionPolicy Bypass -File install-windows-remote.ps1 -ArchivePath local-receipt-printer-deploy.zip'

echo
echo "Remote installation finished."
echo "On Windows, open http://127.0.0.1:17890"
echo "To access it from this Mac, run:"
echo "  ssh -L 17890:127.0.0.1:17890 $remote_target"
