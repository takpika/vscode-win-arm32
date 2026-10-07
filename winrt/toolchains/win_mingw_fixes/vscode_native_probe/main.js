// Electron main-process probe: loads each native module VSCode 1.80.1 ships
// (built by node-gyp with addon_toolchain.py) from ./node_modules and makes one
// real call into its native binding; rewrites --out=<file> (one JSON object)
// after every module, so a module that crashes the process is the first one
// missing from the file; quits.
const { app } = require('electron');
const fs = require('fs');
const os = require('os');
const path = require('path');
const out = process.argv.find(a => a.startsWith('--out=')).slice(6);
const tmp = fs.mkdtempSync(path.join(os.tmpdir(), 'vnp-'));
const r = { exe: path.basename(process.execPath), modules: process.versions.modules };

async function probe(name, fn) {
  r[name] = 'STARTED';
  fs.writeFileSync(out, JSON.stringify(r));
  try {
    r[name] = await Promise.race([
      Promise.resolve().then(fn),
      new Promise((_, reject) => setTimeout(() => reject(new Error('timeout')), 30000))]);
  } catch (e) {
    r[name] = 'ERR ' + (e && e.stack || e);
  }
  fs.writeFileSync(out, JSON.stringify(r));
}

async function main() {
  await probe('spdlog', () => {
    const spdlog = require('@vscode/spdlog');
    const file = path.join(tmp, 'probe.log');
    const logger = new spdlog.Logger('rotating', 'probe', file, 1 << 20, 1);
    logger.info('spdlog-ok');
    logger.flush();
    logger.drop();
    return fs.readFileSync(file, 'utf8').includes('spdlog-ok');
  });
  await probe('sqlite3', () => new Promise((resolve, reject) => {
    const sqlite3 = require('@vscode/sqlite3');
    const db = new sqlite3.Database(':memory:');
    db.serialize(() => {
      db.run('CREATE TABLE t (v TEXT)');
      db.run('INSERT INTO t VALUES (?)', 'sqlite-ok');
      db.get('SELECT v FROM t', (err, row) => err ? reject(err) : resolve(row.v));
    });
  }));
  await probe('native_keymap', () => {
    const keymap = require('native-keymap');
    return { layout: keymap.getCurrentKeyboardLayout(), keys: Object.keys(keymap.getKeyMap()).length };
  });
  await probe('node_pty', () => new Promise((resolve) => {
    // node-pty's own backend choice: ConPTY from Windows build 18309, winpty
    // before (lib/windowsPtyAgent.js).
    const pty = require('node-pty');
    const p = pty.spawn('cmd.exe', ['/c', 'echo pty-ok'], { cols: 80, rows: 24 });
    let data = '';
    p.onData(d => { data += d; });
    p.onExit(e => resolve({
      exitCode: e.exitCode, sawOutput: data.includes('pty-ok'),
      native: Object.keys(require.cache).filter(k => k.endsWith('.node') && k.includes('node-pty'))
          .map(k => path.basename(k)).sort() }));
  }));
  await probe('node_pty_conpty_console_list', () =>
    typeof require('node-pty/build/Release/conpty_console_list.node').getConsoleProcessList);
  await probe('windows_process_tree', () => new Promise((resolve) => {
    require('@vscode/windows-process-tree').getProcessList(process.pid, list => resolve(list && list[0] && list[0].pid === process.pid));
  }));
  await probe('windows_registry', () => require('@vscode/windows-registry').GetStringRegKey(
      'HKEY_LOCAL_MACHINE', 'SOFTWARE\\Microsoft\\Windows NT\\CurrentVersion', 'ProductName'));
  await probe('windows_mutex', () => {
    const m = require('@vscode/windows-mutex');
    const mutex = new m.Mutex('vscode-native-probe');
    const active = m.isActive('vscode-native-probe');
    mutex.release();
    return active;
  });
  await probe('native_watchdog', () => {
    // Watches the given process and exits this one when it dies: our own pid.
    require('native-watchdog').start(process.pid);
    return true;
  });
  // Watchers are torn down as VSCode does before quitting: the parcel
  // subscription is unsubscribed, the policy watcher disposed after it has
  // delivered its first update (VSCode's NativePolicyService disposes it at
  // shutdown, never before its worker has started).
  await probe('parcel_watcher', () => new Promise((resolve, reject) => {
    const watcher = require('@parcel/watcher');
    let subscription;
    watcher.subscribe(tmp, (err, events) => {
      if (err) return reject(err);
      if (events.some(e => e.path.endsWith('watched.txt'))) {
        const type = events[0].type;
        subscription.unsubscribe().then(() => resolve(type), reject);
      }
    }).then(s => {
      subscription = s;
      setTimeout(() => fs.writeFileSync(path.join(tmp, 'watched.txt'), 'x'), 500);
    }, reject);
  }));
  await probe('policy_watcher', () => new Promise(resolve => {
    const watcher = require('@vscode/policy-watcher').createWatcher('VSCodeNativeProbe', { P: { type: 'string' } }, () => {
      watcher.dispose();
      resolve(true);
    });
  }));
  await probe('keytar', async () => {
    const keytar = require('keytar');
    await keytar.setPassword('vscode-native-probe', 'account', 'keytar-ok');
    const v = await keytar.getPassword('vscode-native-probe', 'account');
    await keytar.deletePassword('vscode-native-probe', 'account');
    return v;
  });
  // These two packages' index.js swallow a failed binding load and return
  // false, so the bindings are required and called directly.
  await probe('native_is_elevated', () =>
    typeof require('native-is-elevated/build/Release/iselevated.node').isElevated());
  await probe('windows_foreground_love', () =>
    typeof require('windows-foreground-love/build/Release/foreground_love.node').allowSetForegroundWindow(process.pid));
  r.done = true;
  fs.writeFileSync(out, JSON.stringify(r));
  app.quit();
}

app.whenReady().then(main);
