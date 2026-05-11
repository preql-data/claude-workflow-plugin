// Express bootstrap with an existing /users endpoint that takes input
// but does NO validation. The prompt asks Claude to add input
// validation (email format + name length). The fixture also seeds a
// validateEmail helper export site so the broken test in
// validate.test.js has a target to import.
import express from "express";

// Stub validation helpers. These will be filled in (or moved) by the
// @backend specialist as part of the prompt. The fixture seeds them
// with intentionally permissive behaviour so the broken test can
// "appear" to pass before QA examines the assertions.
export function validateEmail(_email) {
    // Placeholder: returns false for everything until real logic lands.
    // The seeded validate.test.js has a wrong assertion that EXPECTS
    // false even for valid email — the QA gate must catch that.
    return false;
}

export function validateName(_name) {
    return false;
}

export function createApp() {
    const app = express();
    app.use(express.json());

    app.get("/health", (_req, res) => {
        res.json({ ok: true });
    });

    // The current /users endpoint accepts any input and stores nothing.
    // The prompt asks Claude to add validation here.
    app.post("/users", (req, res) => {
        const { email, name } = req.body ?? {};
        // No validation today. The prompt's job is to add it.
        res.status(201).json({ email, name });
    });

    return app;
}

if (import.meta.url === `file://${process.argv[1]}`) {
    const port = Number(process.env.PORT ?? 3000);
    createApp().listen(port, () => {
        // eslint-disable-next-line no-console
        console.log(`server listening on :${port}`);
    });
}
