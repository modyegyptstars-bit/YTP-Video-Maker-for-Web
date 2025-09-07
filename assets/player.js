// player.js — release 1.0 updates (minimal glue)
// - keeps drag/drop, 'p' hotkey, and runner upload flow intact
// - lightweight UI hook spots for per-source controls (UI generation is in index.html / previous scripts)

(function () {
  const player = document.getElementById('preview-player');
  const hint = document.getElementById('player-hint');
  const uploadBtn = document.getElementById('upload-to-runner');
  const wrap = document.getElementById('player-wrap');

  // drag & drop visuals
  ['dragenter','dragover'].forEach(ev => {
    wrap.addEventListener(ev, (e) => { e.preventDefault(); wrap.classList && wrap.classList.add('dragover'); });
  });
  ['dragleave','drop'].forEach(ev => {
    wrap.addEventListener(ev, (e) => { e.preventDefault(); wrap.classList && wrap.classList.remove('dragover'); });
  });

  // handle dropped preview file
  wrap.addEventListener('drop', (e) => {
    e.preventDefault();
    const f = e.dataTransfer.files && e.dataTransfer.files[0];
    if (!f) return alert('No file dropped');
    const url = URL.createObjectURL(f);
    player.src = url;
    player.play().catch(()=>{});
    hint.textContent = `Playing ${f.name}`;
  });

  async function tryOpenPreview() {
    const previewUrl = 'preview.mp4';
    try {
      const res = await fetch(previewUrl, { method: 'HEAD' });
      if (res.ok) {
        player.src = previewUrl;
        player.play().catch(()=>{});
        hint.textContent = `Playing preview.mp4 from server`;
      } else {
        alert('preview.mp4 not found on server. Export config and run the preview runner locally.');
      }
    } catch (err) {
      alert('Unable to check preview.mp4 — are you hosting the site on a server?');
    }
  }

  window.addEventListener('keydown', (e) => {
    if (e.key === 'p') tryOpenPreview();
  });

  // Upload to runner (optional)
  uploadBtn && uploadBtn.addEventListener('click', async () => {
    if (typeof ffmpeg === 'undefined' || !ffmpeg.uploadConfigAndFiles) {
      return alert('No runner client available. See README to run the preview script locally.');
    }
    // User picks config file and associated files; client helper handles upload
    const cfgInput = document.createElement('input');
    cfgInput.type = 'file';
    cfgInput.accept = '.json,application/json';
    cfgInput.onchange = async () => {
      const cfgFile = cfgInput.files[0];
      if (!cfgFile) return;
      try {
        const cfg = JSON.parse(await cfgFile.text());
        // ask user to pick referenced files
        alert('Select source files and overlay files in next dialog (select multiple). Filenames must match those in config.json.');
        const fileInput = document.createElement('input');
        fileInput.type = 'file';
        fileInput.multiple = true;
        fileInput.onchange = async () => {
          const files = Array.from(fileInput.files);
          try {
            const job = await ffmpeg.uploadConfigAndFiles(cfgFile, files);
            hint.textContent = `Upload queued (job ${job.id}). Polling status...`;
            const status = await ffmpeg.pollJobStatus(job);
            if (status && (status.status === 'done' || status.status === 'completed') && status.output_url) {
              player.src = status.output_url;
              player.play().catch(()=>{});
              hint.textContent = 'Preview available from runner';
            } else {
              alert('Runner finished but did not provide a preview URL. Check runner logs.');
            }
          } catch (err) {
            alert('Upload to runner failed: ' + err.message);
          }
        };
        fileInput.click();
      } catch (err) {
        alert('Invalid config.json selected: ' + err.message);
      }
    };
    cfgInput.click();
  });

})();