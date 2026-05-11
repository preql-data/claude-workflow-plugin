// Plain Button — placeholder so the @fixture/ui package isn't empty
// when Claude lands the new RetryButton next to it. The harness expects
// the orchestrator to add a sibling RetryButton.jsx, not to touch this
// existing component.
import React from "react";

export default function Button({ onClick, children, ...rest }) {
    return (
        <button type="button" onClick={onClick} {...rest}>
            {children}
        </button>
    );
}
