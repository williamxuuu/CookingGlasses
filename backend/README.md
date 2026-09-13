# Cooking Glasses observation backend

A Node.js 22+ server with no npm dependencies. It accepts a short, chronological JPEG sequence and current recipe context, asks Gemini 3.6 Flash for one structured observation, validates the result, and returns it to the iOS app. Recipe progression and timers stay in the app. Photo/web recipe imports keep their separate model configuration.

## Run locally

From this directory:

```sh
cp .env.example .env
openssl rand -hex 32
```

Edit `.env`: set `GEMINI_API_KEY` to your Gemini API key and `COOKING_API_TOKEN` to the random token you generated. Keep both private. The token must contain 32–256 letters, digits, or `._~+/-` characters. The app receives only this backend token through runtime Settings; the Gemini key remains on the server.

```sh
npm test
npm run check
npm start
```

There is no install step. `npm start` loads `.env`; use `npm run start:env` when your process manager already provides environment variables. The default listener is `127.0.0.1:8787`. An unauthenticated `GET /health` reports process health and does not contact Gemini.

```sh
curl http://127.0.0.1:8787/health
```

For an iPhone, place the server behind an HTTPS reverse proxy and configure the app with that backend URL and your backend token. The default listener is only reachable on its host. Set `HOST` explicitly for your deployment network; expose only the HTTPS proxy to clients. No service has been deployed by this repository.

See [the backend contract and operational notes](../docs/BACKEND.md) for payloads, limits, errors, and the Gemini integration reference.

## Verification boundary

`npm test` uses generated black JPEG fixtures and injected fake model responses. It exercises actual local HTTP requests, structured Gemini request construction, validation, cancellation, timeouts, and rate/concurrency limits without credentials or paid API requests. It does not establish camera-event recognition accuracy, latency on your network, or availability of Gemini for your account. Those require a deliberate device and live-service trial.
