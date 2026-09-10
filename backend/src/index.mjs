import { createGeminiClassifier } from './gemini.mjs';
import { createObservationServer } from './server.mjs';

function integerEnv(name, fallback, min, max) {
  const value = process.env[name] ?? String(fallback);
  if (!/^\d+$/u.test(value) || Number(value) < min || Number(value) > max) {
    throw new Error(`${name} must be an integer between ${min} and ${max}.`);
  }
  return Number(value);
}

try {
  const port = integerEnv('PORT', 8787, 1, 65535);
  const host = process.env.HOST || '127.0.0.1';
  const classify = createGeminiClassifier({
    apiKey: process.env.GEMINI_API_KEY,
    timeoutMs: integerEnv('GEMINI_TIMEOUT_MS', 15000, 1000, 30000),
  });
  const server = createObservationServer({
    bearerToken: process.env.COOKING_API_TOKEN,
    classify,
    maxRequestsPerMinute: integerEnv('MAX_REQUESTS_PER_MINUTE', 30, 1, 600),
    maxConcurrentRequests: integerEnv('MAX_CONCURRENT_REQUESTS', 2, 1, 16),
  });
  server.on('error', () => {
    console.error('Could not start the observation server. Check the host and port.');
    process.exitCode = 1;
  });
  server.listen(port, host, () => {
    // Startup metadata only. Request payloads, headers and model output are never logged.
    console.info(`Cooking Glasses observation server listening on port ${port}.`);
  });
  const stop = () => {
    server.abortObservations();
    server.close();
    server.closeAllConnections();
  };
  process.once('SIGINT', stop);
  process.once('SIGTERM', stop);
} catch (error) {
  // Configuration errors are generated locally and never interpolate values.
  console.error(error.message);
  process.exitCode = 1;
}
