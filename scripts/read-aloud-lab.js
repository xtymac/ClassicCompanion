// Temporary, opt-in Web Inspector probe. Paste into the inspected ChatGPT page.
// Uses standard browser media APIs only. Does not read URLs, credentials, network
// traffic, message text, or audio samples. Reload or uninstall() removes it.
// Workflow: install before clicking official Read aloud; retainHistory(true);
// inspect snapshot() for the media id; command(id, 'pause-preserving-session'),
// command(id, 'play'), command(id, 'rate', 1.5), command(id, 'seek', +/-15).
// Stop using the official button before uninstall(). Not production integration.
(() => {
  if (location.hostname !== 'chatgpt.com') throw new Error('Expected chatgpt.com');
  if (window.__ccReadAloudLab) return 'already-installed';
  const media = [], contexts = [], sources = [], buffers = [], events = [], restore = [];
  let retainHistory = false;
  const started = performance.now();
  const number = n => Number.isFinite(n) ? Math.round(n * 1000) / 1000 : null;
  const log = (kind, details = {}) => {
    events.push({at: number((performance.now() - started) / 1000), kind, ...details});
    if (events.length > 160) events.shift();
  };
  const ranges = r => Array.from({length: r.length}, (_, i) => [number(r.start(i)), number(r.end(i))]);
  const mediaState = (m, id) => ({id, tag: m.tagName, connected: m.isConnected,
    paused: m.paused, ended: m.ended, time: number(m.currentTime), duration: number(m.duration),
    rate: m.playbackRate, preservesPitch: m.preservesPitch, ready: m.readyState,
    muted: m.muted, volume: m.volume, seekable: ranges(m.seekable), buffered: ranges(m.buffered),
    error: m.error?.code ?? null});
  const rememberContext = c => {
    if (!contexts.includes(c)) { contexts.push(c); log('context-seen', {id: contexts.length - 1}); }
    return contexts.indexOf(c);
  };
  const rememberMedia = m => {
    if (!media.includes(m)) {
      media.push(m);
      const id = media.indexOf(m), initialRate = m.playbackRate;
      const listener = e => log('media-' + e.type, mediaState(m, id));
      const types = ['playing', 'pause', 'ended', 'ratechange', 'seeking', 'seeked', 'error', 'emptied'];
      types.forEach(t => m.addEventListener(t, listener));
      restore.push(() => types.forEach(t => m.removeEventListener(t, listener)));
      restore.push(() => { if (m.playbackRate !== initialRate) m.playbackRate = initialRate; });
      log('media-seen', mediaState(m, id));
    }
    return media.indexOf(m);
  };
  const wrap = (proto, key, before) => {
    const descriptor = Object.getOwnPropertyDescriptor(proto, key);
    if (!descriptor || typeof descriptor.value !== 'function') return;
    const original = descriptor.value;
    const replacement = function(...args) {
      try { before(this); } catch { log('probe-error', {method: key}); }
      return Reflect.apply(original, this, args);
    };
    Object.defineProperty(proto, key, {...descriptor, value: replacement});
    restore.push(() => {
      if (proto[key] === replacement) Object.defineProperty(proto, key, descriptor);
    });
  };
  wrap(HTMLMediaElement.prototype, 'play', m => log('media-play-call', {id: rememberMedia(m)}));
  wrap(HTMLMediaElement.prototype, 'pause', m => log('media-pause-call', {id: rememberMedia(m)}));
  for (const key of ['resume', 'suspend', 'close']) {
    if (window.AudioContext) wrap(AudioContext.prototype, key, c => log('context-' + key, {id: rememberContext(c)}));
  }
  if (window.AudioBufferSourceNode) wrap(AudioBufferSourceNode.prototype, 'start', s => {
    if (!sources.includes(s)) sources.push(s);
    log('buffer-start', {id: sources.indexOf(s), context: rememberContext(s.context),
      duration: number(s.buffer?.duration), rate: s.playbackRate.value});
  });
  // Single-player experiment only: preserve up to 120 seconds behind the playhead.
  // Still call the real remove() so updating/updateend lifecycle stays intact.
  if (window.MediaSource && window.SourceBuffer) {
    const add = Object.getOwnPropertyDescriptor(MediaSource.prototype, 'addSourceBuffer');
    const remove = Object.getOwnPropertyDescriptor(SourceBuffer.prototype, 'remove');
    const addReplacement = function(...args) {
      const buffer = Reflect.apply(add.value, this, args);
      buffers.push({source: this, buffer, mime: String(args[0]).slice(0, 100)});
      log('source-buffer-seen', {id: buffers.length - 1});
      return buffer;
    };
    const removeReplacement = function(start, end) {
      const id = buffers.findIndex(b => b.buffer === this);
      const entry = buffers[id];
      const active = media.filter(m => !m.ended && m.readyState >= 2);
      const open = buffers.filter(b => b.source.readyState === 'open');
      let args = [start, end], kept = false;
      if (retainHistory && entry && active.length === 1 && open.length === 1 &&
          open[0] === entry && start === 0 && Number.isFinite(end) && end <= active[0].currentTime + 0.1) {
        const safeEnd = Math.min(end, active[0].currentTime - 120);
        if (safeEnd > start) args = [start, safeEnd];
        else {
          const duration = entry.source.duration;
          const afterBuffer = this.buffered.length ? this.buffered.end(this.buffered.length - 1) + 1 : 1;
          // remove(duration, Infinity) is empty for finite duration; with an infinite
          // stream, remove beyond its current buffered end instead.
          args = [Number.isFinite(duration) ? duration : afterBuffer, Infinity];
        }
        kept = true;
      }
      log('source-buffer-remove', {id, start: number(start), end: number(end), kept});
      return Reflect.apply(remove.value, this, args);
    };
    Object.defineProperty(MediaSource.prototype, 'addSourceBuffer', {...add, value: addReplacement});
    Object.defineProperty(SourceBuffer.prototype, 'remove', {...remove, value: removeReplacement});
    restore.push(() => {
      if (MediaSource.prototype.addSourceBuffer === addReplacement) Object.defineProperty(MediaSource.prototype, 'addSourceBuffer', add);
      if (SourceBuffer.prototype.remove === removeReplacement) Object.defineProperty(SourceBuffer.prototype, 'remove', remove);
    });
  }
  document.querySelectorAll('audio,video').forEach(rememberMedia);
  const snapshot = () => ({media: media.map(mediaState), contexts: contexts.map((c, id) => ({id,
    state: c.state, time: number(c.currentTime), sampleRate: c.sampleRate})), sources: sources.length,
    buffers: buffers.map((b, id) => ({id, state: b.source.readyState, mime: b.mime,
      buffered: b.source.readyState === 'closed' ? [] : ranges(b.buffer.buffered)})), retainHistory,
    controls: Array.from(document.querySelectorAll('button,[role=checkbox],[role=button]'))
      .map(b => b.getAttribute('aria-label') || '')
      .filter(s => /^(read aloud|stop reading aloud|pause|resume|play|playback speed)$/i.test(s)),
    events: events.slice(-24)});
  const get = id => {
    if (!Number.isInteger(id) || !media[id]) throw new Error('Unknown media id');
    return media[id];
  };
  window.__ccReadAloudLab = {
    snapshot,
    retainHistory(enabled) { retainHistory = enabled === true; return retainHistory; },
    async measure(id, seconds = 2) {
      if (!(seconds >= 0.5 && seconds <= 10)) throw new Error('Invalid measurement duration');
      const m = get(id), before = mediaState(m, id), time = performance.now();
      await new Promise(resolve => setTimeout(resolve, seconds * 1000));
      const wall = (performance.now() - time) / 1000, after = mediaState(m, id);
      return {before, after, wall: number(wall), effectiveRate: number((after.time - before.time) / wall)};
    },
    async command(id, action, value) {
      const m = get(id), before = mediaState(m, id);
      if (action === 'pause-preserving-session') {
        if (!m.paused) {
          // The official page treats pause as Stop and empties this audio element.
          // Suppress only the pause event caused by this explicit experiment.
          // Official Stop remains untouched after this single event is consumed.
          const guard = e => { e.stopImmediatePropagation(); log('lab-pause-preserved', {id}); };
          m.addEventListener('pause', guard, {capture: true, once: true});
          restore.push(() => m.removeEventListener('pause', guard, true));
          m.pause();
        }
      } else if (action === 'pause') m.pause();
      else if (action === 'play') await m.play();
      else if (action === 'rate') {
        if (![0.75, 1, 1.25, 1.5, 1.75, 2].includes(value)) throw new Error('Invalid rate');
        m.playbackRate = value;
      } else if (action === 'seek') {
        if (![-15, 15].includes(value)) throw new Error('Only +/-15 seconds');
        const target = m.currentTime + value;
        if (!Array.from({length: m.seekable.length}, (_, i) => i)
          .some(i => target >= m.seekable.start(i) && target < m.seekable.end(i))) {
          return {status: 'outside-seekable-range', before, requested: number(target)};
        }
        // On this site seekable can include data already discarded by SourceBuffer.remove.
        if (!Array.from({length: m.buffered.length}, (_, i) => i)
          .some(i => target >= m.buffered.start(i) && target < m.buffered.end(i))) {
          return {status: 'outside-buffered-range', before, requested: number(target)};
        }
        m.currentTime = target;
      } else throw new Error('Unknown action');
      return {status: 'applied', action, before, after: mediaState(m, id)};
    },
    uninstall() { restore.reverse().forEach(f => f()); delete window.__ccReadAloudLab; return 'removed'; },
  };
  return 'CC_READ_ALOUD_LAB_INSTALLED';
})();
