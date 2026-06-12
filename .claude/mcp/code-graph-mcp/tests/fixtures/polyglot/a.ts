// a.ts — exported symbol used by b.ts (resolves cross-file).
// The orphan-export seed for dead_code lives in orphan.ts (a leaf file
// nothing imports) so dead_code's "is the file imported by anyone?"
// check correctly returns "no".

export function getCurrentTask(): string {
    return "task-1";
}

export const SOME_CONSTANT = 42;

export class TaskHandler {
    handle(): string {
        return getCurrentTask();
    }
}
