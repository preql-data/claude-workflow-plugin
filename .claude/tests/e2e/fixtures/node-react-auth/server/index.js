// Express bootstrap. The fixture prompt will ask Claude to add real
// endpoints (POST /auth/login with JWT). Today this is just a server
// shell so QA's `npm test` and lint/typecheck have something to chew on.

import express from "express";

export function createApp() {
    const app = express();
    app.use(express.json());

    app.get("/health", (_req, res) => {
        res.json({ ok: true });
    });

    return app;
}

// When run directly, listen. When imported (e.g. by tests), just export.
if (import.meta.url === `file://${process.argv[1]}`) {
    const port = Number(process.env.PORT ?? 3000);
    createApp().listen(port, () => {
        // eslint-disable-next-line no-console
        console.log(`server listening on :${port}`);
    });
}
