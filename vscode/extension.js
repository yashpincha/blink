// blink companion: loads only when blink opens
//   vscode://yashpincha.blink/focus?pid=<claude pid>&pid=<its shell pid>…
// and shows the integrated terminal running that process. Nothing else.
const vscode = require('vscode');

exports.activate = (context) => {
  context.subscriptions.push(vscode.window.registerUriHandler({
    async handleUri(uri) {
      if (uri.path !== '/focus') return;
      const pids = new URLSearchParams(uri.query).getAll('pid').map(Number).filter(Boolean);
      for (const terminal of vscode.window.terminals) {
        if (pids.includes(await terminal.processId)) {
          terminal.show(false);
          return;
        }
      }
    },
  }));
};

exports.deactivate = () => {};
