// @fixture/app entry — minimal consumer that imports Button from
// @fixture/ui. After the prompt lands, this file may also import
// RetryButton if Claude decides to demonstrate consumption — but the
// spec doesn't require it. The fixture's primary assertion is that
// the orchestrator scoped the change to packages/ui only.
import { Button } from "@fixture/ui";

export default function App() {
    return Button;
}
