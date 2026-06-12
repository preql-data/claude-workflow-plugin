// c.js — JS (not TS) caller; exercises grammar selection per extension.
// Also seeds a transitive caller for the impact_of test:
//   topLevel -> useTaskHandler -> handle -> getCurrentTask
//
// (handle is on a.ts's TaskHandler class — the static resolver binds
// it by name across files.)

const { TaskHandler } = require('./a');

function topLevel() {
    return useTaskHandler();
}

function useTaskHandler() {
    const h = new TaskHandler();
    return h.handle();
}

module.exports = { topLevel };
