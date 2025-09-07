// ffmpeg.js — client helper (unchanged interface, kept for release 1.0)
// - uploadConfigAndFiles(configFile, files[]) posts to /render and expects { id, status_url }
// - pollJobStatus(job) polls job.statusUrl until done
window.ffmpeg = {
  uploadConfigAndFiles: async function (configFile, files, opts = {}) {
    const url = opts.url || '/render';
    const fd = new FormData();
    fd.append('config', configFile, configFile.name || 'config.json');
    files.forEach((f) => fd.append('files[]', f));
    const r = await fetch(url, { method: 'POST', body: fd });
    if (!r.ok) throw new Error('Upload failed: ' + r.statusText);
    const body = await r.json();
    return { id: body.id || body.job_id || null, statusUrl: body.status_url || body.statusUrl || (`/render/${body.id}/status`) };
  },

  pollJobStatus: async function (job, opts = {}) {
    const pollInterval = opts.pollInterval || 2000;
    const maxAttempts = opts.maxAttempts || 300;
    let attempts = 0;
    if (!job || !job.statusUrl) {
      if (job && job.id) job.statusUrl = `/render/${job.id}/status`;
      else throw new Error('Job missing statusUrl');
    }
    while (attempts++ < maxAttempts) {
      try {
        const r = await fetch(job.statusUrl);
        if (!r.ok) throw new Error('Status poll failed: ' + r.statusText);
        const s = await r.json();
        if (s.status === 'done' || s.status === 'completed') return s;
        if (s.status === 'error' || s.status === 'failed') throw new Error('Job failed: ' + (s.error || 'unknown'));
      } catch (err) {
        if (attempts > 10) throw err;
      }
      await new Promise(r => setTimeout(r, pollInterval));
    }
    throw new Error('Polling timeout');
  }
};