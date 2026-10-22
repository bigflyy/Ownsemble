'use strict';

// Invoked only by the guarded music reader after an explicit Import click.
// No text, HTML, field values, URLs, script contents, or framework state is read.
function inspectMusicDOM() {
  const selectors = {
    frames: 'iframe', audioElements: 'audio', listItems: '[role="listitem"]',
    audioIds: '[data-audio-id]', trackIds: '[data-track-id]',
    testIds: '[data-testid]', testIdsAlternate: '[data-test-id]',
    busyRegions: '[aria-busy="true"]',
  };
  const counts = {};
  for (const [name, selector] of Object.entries(selectors)) {
    counts[name] = document.querySelectorAll(selector).length;
  }
  counts.elementsExamined = 0;
  counts.openShadowRoots = 0;
  const components = {};
  for (const marker of ['MusicTrackRow_Title', 'MusicTrackRow_Authors', 'MusicTrackRow_Duration']) {
    const count = document.querySelectorAll(`[data-testid="${marker}"]`).length;
    if (count) components[marker] = count;
  }
  for (const row of document.querySelectorAll('[data-audio-id]')) {
    for (const element of row.querySelectorAll('[data-testid]')) {
      const marker = element.getAttribute('data-testid');
      if (typeof marker === 'string' && marker.length <= 64 &&
          /^Music(?:TrackRow|Audio)_[A-Za-z_]+$/.test(marker) && !Object.hasOwn(components, marker) &&
          Object.keys(components).length < 60) components[marker] = 1;
    }
  }
  const visit = (root, depth = 0) => {
    if (depth > 3 || counts.elementsExamined >= 20000) return;
    for (const element of root.querySelectorAll('*')) {
      if (counts.elementsExamined >= 20000) break;
      counts.elementsExamined++;
      if (['INPUT', 'TEXTAREA', 'SELECT', 'SCRIPT', 'STYLE', 'IFRAME'].includes(element.tagName)) continue;
      // Only public music-related CSS component names, stripped of hashes/IDs.
      for (const token of element.classList || []) {
        const component = token.split(/__|--/)[0].replace(/[0-9].*$/, '');
        if (component.length <= 64 && /^[a-zA-Z_-]+$/.test(component) &&
            /audio|music|track|song|catalog/i.test(component)) {
          if (Object.hasOwn(components, component)) components[component]++;
          else if (Object.keys(components).length < 60) components[component] = 1;
        }
      }
      if (element.shadowRoot) {
        counts.openShadowRoots++;
        visit(element.shadowRoot, depth + 1);
      }
    }
  };
  visit(document);
  return { counts, components };
}

function sanitizeMusicStructure(value) {
  const counts = {};
  for (const key of ['frames', 'audioElements', 'listItems', 'audioIds', 'trackIds',
    'testIds', 'testIdsAlternate', 'busyRegions', 'elementsExamined', 'openShadowRoots']) {
    const number = value?.counts?.[key];
    if (Number.isSafeInteger(number) && number >= 0 && number <= 1000000) counts[key] = number;
  }
  const components = {};
  for (const [key, number] of Object.entries(value?.components || {}).slice(0, 60)) {
    if (key.length <= 64 && /^[a-zA-Z_-]+$/.test(key) && /audio|music|track|song|catalog/i.test(key) &&
        Number.isSafeInteger(number) && number >= 1 && number <= 1000000) components[key] = number;
  }
  return { counts, components };
}

module.exports = { inspectMusicDOM, sanitizeMusicStructure };
