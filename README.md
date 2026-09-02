# Local Receipt Printer

A dependency-free Node.js print bridge for an Epson TM-m30III (and compatible ESC/POS receipt printers) connected by USB. It runs a website and JSON API on this computer at `http://127.0.0.1:17890`.

The API accepts browser requests from the exact production Glass Pane origin, `https://glass-pane.aistone.com`, while remaining bound to loopback. Other remote origins are rejected. Edge may ask the kiosk user once for permission to access a device on the local network.

The service sends raw ESC/POS bytes through the operating system's print spooler:

- macOS: CUPS (`lp`/`lpstat`)
- Windows: the Windows spooler (`winspool.drv`, RAW data type)

This is more dependable than talking directly to USB: the Epson or Windows USB driver owns reconnects, the spooler accepts RAW jobs, and the app rediscovers and repairs the TM-m30III queue continuously and before every print attempt.

On Windows, production installation uses a real automatic boot-time service. It starts before any user login, stays alive independently if the Windows Print Spooler restarts, and restarts five seconds after its own process crashes. It is machine-wide, so the `kiosk` user and Edge kiosk can use it without a per-user startup item. Unaccepted jobs exist only in memory and are discarded when the service restarts; the app never replays an old receipt after reboot.

## Install

1. Install Node.js 20 or newer.
2. Install Epson's TM-m30III Mac Printer Driver on macOS or Advanced Printer Driver (APD) on Windows, then add the USB printer in the operating system's printer settings.
3. In this folder, run:

   ```sh
   npm test
   npm run install-service
   ```

4. Open [http://127.0.0.1:17890](http://127.0.0.1:17890), select the printer if needed, and print a test receipt.

No `npm install` is required because the app has no third-party runtime packages.

## Remote Windows installation from a Mac

The installer configures Windows OpenSSH with the development Mac's public key and a source-IP-limited firewall rule. It then downloads and verifies a private portable Node.js runtime and WinSW service wrapper, copies the app into protected `%ProgramFiles%\LocalReceiptPrinter`, stores settings under `%ProgramData%\LocalReceiptPrinter`, runs its tests, checks or repairs the Windows USB printer queue, installs the boot-time service, verifies `/api/health`, and submits a physical USB test receipt. Every SSH and installation success or failure is reported automatically to the Mac; screenshots are not required.

### One-time Windows preparation

1. Connect and power on the TM-m30III using its USB-B computer connection.
2. Copy both `scripts\enable-windows-remote.cmd` and `scripts\enable-windows-remote.ps1` to the same folder on Windows.
3. Double-click `enable-windows-remote.cmd`. Approve the administrator prompt.
4. Note the username and IP address printed by the script. The Windows network must be marked **Private**.

This enables Windows OpenSSH on TCP port 22 for Private networks only. SSH uses the Windows account password, not a Windows Hello PIN.

### Deploy from the Mac

From this project folder, run:

```sh
./scripts/deploy-windows-remote.sh WINDOWS_USER@WINDOWS_IP
```

Example:

```sh
./scripts/deploy-windows-remote.sh ahron@192.168.1.42
```

The command packages the current source, asks for the Windows account password once, transfers the files, installs the app, and reports whether the printer was discovered. Afterward, open `http://127.0.0.1:17890` on Windows.

To reach the Windows-only website temporarily from the Mac without exposing it to the LAN:

```sh
ssh -L 17890:127.0.0.1:17890 WINDOWS_USER@WINDOWS_IP
```

Then open `http://127.0.0.1:17890` on the Mac while that SSH session remains open.

The TM-m30III defaults to the standard USB printer class. When Windows exposes one unambiguous USB printer port, the installer creates or repairs the queue automatically, preferring an installed Epson driver and otherwise installing the built-in `Generic / Text Only` driver for RAW spooler jobs. If the USB hardware exists but Windows has not enumerated its `USB00x` printer port, the installer restarts that exact Epson device and the Print Spooler, rescans it, and retries. If Windows still sees the Epson USB hardware but no safe queue can be created, the installer downloads the official Epson APD6 package, verifies its fixed SHA-256 hash and Epson Authenticode signature, and opens its one-time printer-registration wizard.

### Start manually

```sh
npm start
```

For development with automatic restarts after file changes:

```sh
npm run dev
```

Nodemon is intentionally not used in production. macOS uses `launchd`; Windows uses a real automatic boot-time service that runs without a user login and stays independent of Print Spooler restarts.

### Remove automatic startup

```sh
npm run uninstall-service
```

Settings and logs are kept so a reinstall retains the selected printer.

## API

### Print text

```sh
curl -X POST http://127.0.0.1:17890/api/print \
  -H "Content-Type: application/json" \
  -d '{"text":"Order 1234\nTotal: $12.34\n","copies":1,"cut":true,"openDrawer":false}'
```

The response is returned after the operating system spooler accepts the job. This confirms spooler acceptance, not that paper physically came out.

### Print raw ESC/POS

```sh
curl -X POST http://127.0.0.1:17890/api/print/raw \
  -H "Content-Type: application/json" \
  -d '{"dataBase64":"G0BIZWxsbyEKCgodVkIA","copies":1}'
```

`dataBase64` may contain up to 2 MB of raw printer bytes.

### Discovery and health

- `GET /api/status` — installed printers, selected printer, queue, and last job
- `GET /api/printers` — same discovery payload as status
- `GET /api/health` — process liveness without touching the print system
- `POST /api/config` with `{"printerName":"installed printer name"}` — persist a printer

### Exit Windows kiosk mode

On the installed Windows service only, the trusted Glass Pane kiosk can request
an exit from Assigned Access:

```sh
curl -X POST http://127.0.0.1:17890/api/windows/kiosk-exit \
  -H "Content-Type: application/json" \
  -d '{"action":"exit-kiosk"}'
```

The installer builds a small protected Windows helper that signs out the active
console session using the Windows Terminal Services API. This reaches the
Windows sign-in screen without granting software permission to synthesize the
machine-wide Secure Attention Sequence. Requests are exact-origin protected,
limited to one every five seconds, logged, and never retried automatically.

Requests are processed one at a time. A failed spool attempt triggers fresh USB queue discovery and up to five bounded attempts over roughly 22 seconds. The response succeeds only after the Windows spooler accepts the job. Unaccepted jobs are not persisted or replayed after a restart. The API only binds to `127.0.0.1` by default and rejects browser requests from non-local origins.

## Settings and logs

macOS:

```text
~/Library/Application Support/LocalReceiptPrinter/config.json
~/Library/Application Support/LocalReceiptPrinter/service.log
```

Windows service installation:

```text
%ProgramData%\LocalReceiptPrinter\config.json
%ProgramData%\LocalReceiptPrinter\service.log
%ProgramData%\LocalReceiptPrinter\wrapper-logs\
```

The log rotates at 5 MB. `service.log.1` is the previous file.

Environment overrides:

- `LOCAL_RECEIPT_PRINTER_PORT` — default `17890`
- `LOCAL_RECEIPT_PRINTER_HOST` — default `127.0.0.1`; changing this exposes the API and requires your own authentication/firewall design
- `LOCAL_RECEIPT_PRINTER_DATA_DIR` — alternate settings/log/job directory

## Reliability boundaries

The service can restart itself, tolerate Print Spooler restarts, recreate an unambiguous missing USB queue, relink its managed queue when Windows moves the printer to another `USB00x` port, rediscover a renamed/reconnected TM-m30III, and retry while the caller is waiting. It never silently falls back to an unrelated printer. No software can guarantee physical printing when the printer has no power, paper is out, the USB cable is disconnected, or Windows cannot expose the USB device. The installer therefore submits a physical test receipt, and the status page and logs preserve auditable evidence afterward.
