// Claude Tabs: reads or changes the app that handles claude:// links.
// Usage: osascript -l JavaScript url-handler.js get
//        osascript -l JavaScript url-handler.js set <bundle id>
ObjC.import('CoreServices');

function run(argv) {
  var scheme = $('claude');
  if (argv[0] === 'set') {
    var status = $.LSSetDefaultHandlerForURLScheme(scheme, $(argv[1]));
    if (status !== 0) throw new Error('LSSetDefaultHandlerForURLScheme: ' + status);
  }
  return ObjC.castRefToObject($.LSCopyDefaultHandlerForURLScheme(scheme)).js;
}
