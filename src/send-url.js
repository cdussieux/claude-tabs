// Claude Tabs: sends a claude:// link to ONE given Claude instance (by pid),
// instead of letting macOS pick the first one that was started.
// Usage: osascript -l JavaScript send-url.js <pid> <url>
ObjC.import('Foundation');

function run(argv) {
  var pid = parseInt(argv[0], 10);
  var url = argv[1];
  var GURL = 0x4755524c;            // kInternetEventClass / kAEGetURL ('GURL')
  var DIRECT_OBJECT = 0x2d2d2d2d;   // keyDirectObject ('----')
  var target = $.NSAppleEventDescriptor.descriptorWithProcessIdentifier(pid);
  var ev = $.NSAppleEventDescriptor
    .appleEventWithEventClassEventIDTargetDescriptorReturnIDTransactionID(GURL, GURL, target, -1, 0);
  ev.setParamDescriptorForKeyword($.NSAppleEventDescriptor.descriptorWithString(url), DIRECT_OBJECT);
  var err = Ref();
  var reply = ev.sendEventWithOptionsTimeoutError(0x1 /* no reply expected */, 5, err);
  if (reply.isNil() && err[0] && !err[0].isNil()) {
    throw new Error(err[0].localizedDescription.js);
  }
  return 'sent';
}
