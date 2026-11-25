// Adds or removes the Claude Tabs hooks in a Claude Code settings.json,
// keeping everything else as it is. Uses JavaScript for Automation, which
// every Mac has, so no Python or Node is needed.
// Usage: osascript -l JavaScript claude-settings.js add|remove <settings.json> <hook.sh>
ObjC.import('Foundation');

var MARK = 'claude-tabs/hook.sh';
var WANTED = {
  UserPromptSubmit: [[null, 'prompt']],
  Stop: [[null, 'stop']],
  Notification: [[null, 'attention']],
  // Claude asks you a question (AskUserQuestion): the session waits for you.
  PreToolUse: [['AskUserQuestion', 'attention']],
  PostToolUse: [['AskUserQuestion', 'answered']],
};

function readText(path) {
  var s = $.NSString.stringWithContentsOfFileEncodingError(path, $.NSUTF8StringEncoding, null);
  return s.isNil() ? null : s.js;
}

function writeText(path, text) {
  var ok = $(text).writeToFileAtomicallyEncodingError(path, true, $.NSUTF8StringEncoding, null);
  if (!ok) throw new Error('cannot write ' + path);
}

function removeOurs(hooks) {
  Object.keys(hooks).forEach(function (event) {
    var groups = (hooks[event] || []).map(function (g) {
      g.hooks = (g.hooks || []).filter(function (h) {
        return (h.command || '').indexOf(MARK) === -1;
      });
      return g;
    }).filter(function (g) { return g.hooks.length > 0; });
    if (groups.length) hooks[event] = groups; else delete hooks[event];
  });
}

function run(argv) {
  var action = argv[0], path = argv[1], hook = argv[2];
  var text = readText(path);
  var data = text && text.trim() ? JSON.parse(text) : {};
  var hooks = data.hooks || {};
  removeOurs(hooks);
  if (action === 'add') {
    Object.keys(WANTED).forEach(function (event) {
      WANTED[event].forEach(function (entry) {
        var group = { hooks: [{ type: 'command', command: "'" + hook + "' " + entry[1], timeout: 5 }] };
        if (entry[0]) group.matcher = entry[0];
        (hooks[event] = hooks[event] || []).push(group);
      });
    });
  } else if (action !== 'remove') {
    throw new Error('usage: add|remove <settings.json> <hook.sh>');
  }
  if (Object.keys(hooks).length) data.hooks = hooks; else delete data.hooks;
  writeText(path, JSON.stringify(data, null, 2) + '\n');
  return action + ' ok';
}
