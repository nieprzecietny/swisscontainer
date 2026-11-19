// Uruchamiane przy budowaniu obrazu (jako root) Node'em narzędziowym z /opt/devc-node.
// Dla każdego pakietu CLI zainstalowanego w /opt/devc-tools tworzy wrapper w /usr/local/bin,
// który ZAWSZE uruchamia CLI na /opt/devc-node — niezależnie od wersji Node wybranej przez fnm
// w projekcie. Procesy potomne (np. `npm test` uruchomione przez agenta) dziedziczą zwykły PATH,
// więc działają na wersji Node projektu.
'use strict';
const fs = require('fs');
const path = require('path');

const ROOT = '/opt/devc-tools/lib/node_modules';
const NODE = '/opt/devc-node/bin/node';
const OUT = '/usr/local/bin';

const pkgs = process.argv.slice(2);
if (pkgs.length === 0) { console.error('użycie: make-cli-wrappers.js <pakiet>...'); process.exit(2); }

for (const pkg of pkgs) {
  const dir = path.join(ROOT, pkg);
  const pj = JSON.parse(fs.readFileSync(path.join(dir, 'package.json'), 'utf8'));
  const bins = typeof pj.bin === 'string' ? { [pj.name.split('/').pop()]: pj.bin } : (pj.bin || {});
  if (Object.keys(bins).length === 0) { console.error(`${pkg}: brak pola "bin"`); process.exit(1); }

  for (const [name, rel] of Object.entries(bins)) {
    const target = path.join(dir, rel);
    const head = fs.readFileSync(target).subarray(0, 128).toString('latin1');
    const firstLine = head.split('\n')[0];
    const isNodeScript = firstLine.startsWith('#!')
      ? /\bnode\b/.test(firstLine)
      : /\.(c|m)?js$/.test(target);

    const exec = isNodeScript ? `exec ${NODE} "${target}" "$@"` : `exec "${target}" "$@"`;
    const body = [
      '#!/bin/sh',
      `# wrapper devcontainera (${pkg}): CLI zawsze na Node z /opt/devc-node, niezależnie od fnm`,
      exec,
      '',
    ].join('\n');

    fs.writeFileSync(path.join(OUT, name), body, { mode: 0o755 });
    console.log(`${name} -> ${isNodeScript ? NODE + ' ' : ''}${target}`);
  }
}
