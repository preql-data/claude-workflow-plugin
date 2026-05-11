// Express bootstrap for the multi-domain-signup fixture.
//
// Today this is just a server shell with a /health endpoint. The fixture
// prompt asks Claude to implement user signup end-to-end (API + UI +
// migration), so this file is one of three sites that grows in the
// happy path: a POST /signup route handler arrives here.
import express from "express";

export function createApp() {
    const app = express();
    app.use(express.json());

    app.get("/health", (_req, res) => {
        res.json({ ok: true });
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
