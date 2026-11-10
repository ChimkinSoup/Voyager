"use strict";

// Debug builds only: cdb attaches this to each companion the main instance
// launches (gaia_pipe.cpp), logging to gaia/companion_cdb.log. A crash logs
// its stack and leaves a full dump beside the log.

// The second chance of these is a crash: logged and dumped, then the
// companion is ended so the main instance relaunches it. On the first chance
// they go to the process, as they would without a debugger.
const kCrashEvents =
    ["av", "sov", "bpe", "eh", "asrt", "dz", "ii", "iov", "ip", "isc", "lsq",
     "sbo", "ssec", "vcpp", "gp", "*"];

function log(text) {
  host.diagnostics.debugLog(text + "\n");
}

function run(command) {
  return host.namespace.Debugger.Utility.Control.ExecuteCommand(command);
}

function stamp() {
  const now = new Date();
  const two = (v) => String(v).padStart(2, "0");
  return `${now.getFullYear()}-${two(now.getMonth() + 1)}-${two(now.getDate())}` +
      `T${two(now.getHours())}:${two(now.getMinutes())}:${two(now.getSeconds())}` +
      `.${String(now.getMilliseconds()).padStart(3, "0")}`;
}

function invokeScript() {
  log(`${stamp()} [cdb] attached`);
  for (const event of kCrashEvents) {
    run(`sxd -c2 "dx -r0 @$scriptContents.onCrash(); .ecxr; kn 40; ` +
        `.dump /ma /u companion.dmp; .kill; q" ${event}`);
  }
}

function onCrash() {
  log(`${stamp()} [cdb] CRASH`);
}
