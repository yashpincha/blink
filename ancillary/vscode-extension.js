// Handles vscode://yashpincha.blink/focus?pid=…&pid=…: shows the integrated
// terminal running one of those processes.
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
