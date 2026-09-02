'use strict';

const elements = {
  status: document.querySelector('#service-status'),
  printer: document.querySelector('#printer'),
  printerDetail: document.querySelector('#printer-detail'),
  savePrinter: document.querySelector('#save-printer'),
  refresh: document.querySelector('#refresh'),
  receipt: document.querySelector('#receipt'),
  copies: document.querySelector('#copies'),
  cut: document.querySelector('#cut'),
  drawer: document.querySelector('#drawer'),
  print: document.querySelector('#print'),
  message: document.querySelector('#message'),
};

async function api(url, options = {}) {
  const response = await fetch(url, options);
  const result = await response.json();
  if (!response.ok || !result.ok) throw new Error(result.error || `Request failed (${response.status})`);
  return result;
}

function setStatus(kind, text) {
  elements.status.className = `status ${kind}`;
  elements.status.innerHTML = '<span></span>';
  elements.status.append(document.createTextNode(text));
}

async function refresh() {
  elements.refresh.disabled = true;
  try {
    const result = await api('/api/status');
    elements.printer.replaceChildren();
    const automatic = document.createElement('option');
    automatic.value = '';
    automatic.textContent = 'Automatic selection';
    elements.printer.append(automatic);
    for (const printer of result.printers) {
      const option = document.createElement('option');
      option.value = printer.name;
      option.textContent = `${printer.name}${printer.isOffline ? ' (offline)' : ''}${printer.isDefault ? ' — default' : ''}`;
      elements.printer.append(option);
    }
    elements.printer.value = result.config.printerName || '';
    elements.printer.disabled = false;
    elements.savePrinter.disabled = false;

    if (result.selectedPrinter) {
      const selected = result.selectedPrinter;
      setStatus(selected.isOffline ? 'error' : 'ready', selected.isOffline ? 'Printer offline' : 'Ready');
      elements.printerDetail.textContent = `${selected.name} · ${result.selectionReason}`;
      elements.print.disabled = selected.isOffline;
    } else {
      setStatus('error', 'Printer needed');
      elements.printerDetail.textContent = result.selectionReason;
      elements.print.disabled = true;
    }
  } catch (error) {
    setStatus('error', 'Service error');
    elements.printerDetail.textContent = error.message;
    elements.print.disabled = true;
  } finally {
    elements.refresh.disabled = false;
  }
}

elements.savePrinter.addEventListener('click', async () => {
  elements.savePrinter.disabled = true;
  elements.message.textContent = 'Saving…';
  try {
    await api('/api/config', {
      method: 'POST',
      headers: { 'Content-Type': 'application/json' },
      body: JSON.stringify({ printerName: elements.printer.value || null }),
    });
    elements.message.textContent = 'Printer selection saved.';
    await refresh();
  } catch (error) {
    elements.message.textContent = error.message;
  } finally {
    elements.savePrinter.disabled = false;
  }
});

elements.refresh.addEventListener('click', refresh);

elements.print.addEventListener('click', async () => {
  if (!elements.receipt.value) {
    elements.message.textContent = 'Enter some receipt text first.';
    elements.receipt.focus();
    return;
  }
  elements.print.disabled = true;
  elements.message.textContent = 'Sending to printer…';
  try {
    const result = await api('/api/print', {
      method: 'POST',
      headers: { 'Content-Type': 'application/json' },
      body: JSON.stringify({
        text: elements.receipt.value,
        copies: Number(elements.copies.value),
        cut: elements.cut.checked,
        openDrawer: elements.drawer.checked,
      }),
    });
    elements.message.textContent = `Job ${result.job.jobId.slice(0, 8)} was accepted by the print spooler.`;
  } catch (error) {
    elements.message.textContent = `Print failed: ${error.message}`;
  } finally {
    elements.print.disabled = false;
  }
});

refresh();
setInterval(refresh, 30_000);
