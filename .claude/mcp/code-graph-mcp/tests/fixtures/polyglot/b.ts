// b.ts — two callers of getCurrentTask plus one path through middle().

import { getCurrentTask, SOME_CONSTANT } from "./a";

export function callerOne(): string {
    return getCurrentTask();
}

export function callerTwo(): string {
    return getCurrentTask();
}

// middle is the BRIDGE used by the dependency_path test: a -> middle -> deep.
export function middle(): string {
    return deep();
}

export function deep(): string {
    return "deep value " + SOME_CONSTANT;
}
