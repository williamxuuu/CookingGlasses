import { createServer } from 'node:http';
import { createHash, timingSafeEqual } from 'node:crypto';
import { HTTPError, invalidRequest } from './errors.mjs';
import { LIMITS, validateRequest, validateObservation } from './validation.mjs';

function sendJSON(response, status, value, extraHeaders = {}) {
  if (response.destroyed || response.writableEnded) return;
  response.writeHead(status, {
    'content-type': 'application/json; charset=utf-8',
    'cache-control': 'no-store',
    'x-content-type-options': 'nosniff',
    ...extraHeaders,
  });
  response.end(JSON.stringify(value));
}

function readBody(request) {
  return new Promise((resolve, reject) => {
    const chunks = [];
    let size = 0;
    const finish = (error, value) => {
      clearTimeout(timeout);
      request.removeListener('data', onData);
      request.removeListener('end', onEnd);
      request.removeListener('error', onError);
      request.removeListener('aborted', onAborted);
      chunks.length = 0;
      if (error) reject(error);
      else resolve(value);
    };
    const onData = (chunk) => {
      size += chunk.length;
      if (size > LIMITS.maxBodyBytes) {
        request.pause();
        finish(new HTTPError(413, 'request_too_large', 'The request exceeds the 6 MiB limit.'));
      } else chunks.push(chunk);
    };
    const onEnd = () => {
      try {
        const value = JSON.parse(Buffer.concat(chunks, size).toString('utf8'));
        finish(null, value);
      } catch {
        finish(invalidRequest('The request body must be valid JSON.'));
      }
    };
    const onError = () => finish(invalidRequest('The request body could not be read.'));
    const onAborted = () => finish(invalidRequest('The request was interrupted.'));
    const timeout = setTimeout(() => {
      request.pause();
      finish(new HTTPError(408, 'request_timeout', 'The request body was not received in time.'));
    }, LIMITS.bodyTimeoutMs);
    request.on('data', onData);
    request.once('end', onEnd);
    request.once('error', onError);
    request.once('aborted', onAborted);
  });
}

export function createObservationServer({ bearerToken, classify, maxRequestsPerMinute = 30,
  maxConcurrentRequests = 2, now = () => Date.now() }) {
  if (typeof bearerToken !== 'string' || !/^[A-Za-z0-9._~+\/-]{32,256}$/u.test(bearerToken)) {
    throw new Error('COOKING_API_TOKEN must contain 32–256 token characters.');
  }
  if (typeof classify !== 'function') throw new Error('An observation classifier is required.');
  if (!Number.isInteger(maxRequestsPerMinute) || maxRequestsPerMinute < 1
      || !Number.isInteger(maxConcurrentRequests) || maxConcurrentRequests < 1) {
    throw new Error('Rate and concurrency limits must be positive integers.');
  }
  const expectedHash = createHash('sha256').update(bearerToken).digest();
  let active = 0;
  const acceptedAt = [];
  const controllers = new Set();
  const server = createServer({ maxHeaderSize: 8192, requestTimeout: 15000,
    headersTimeout: 10000, connectionsCheckingInterval: 1000, keepAliveTimeout: 5000 }, async (request, response) => {
    const controller = new AbortController();
    const onClose = () => { if (!response.writableEnded) controller.abort(); };
    response.once('close', onClose);
    let ownsSlot = false;
    try {
      if (request.url === '/health' && request.method === 'GET') {
        sendJSON(response, 200, { status: 'ok' });
        return;
      }
      if (request.url !== '/v1/cooking/observe') throw new HTTPError(404, 'not_found', 'Route not found.');
      if (request.method !== 'POST') {
        response.setHeader('Allow', 'POST');
        throw new HTTPError(405, 'method_not_allowed', 'Use POST for observations.');
      }
      const authorization = request.headers.authorization;
      const supplied = typeof authorization === 'string' && authorization.startsWith('Bearer ')
        ? authorization.slice(7) : '';
      if (!timingSafeEqual(expectedHash, createHash('sha256').update(supplied).digest())) {
        response.setHeader('WWW-Authenticate', 'Bearer');
        throw new HTTPError(401, 'unauthorized', 'A valid bearer token is required.');
      }
      const currentTime = now();
      while (acceptedAt.length && acceptedAt[0] <= currentTime - 60000) acceptedAt.shift();
      if (acceptedAt.length >= maxRequestsPerMinute) {
        const retryAfter = Math.max(1, Math.ceil((acceptedAt[0] + 60000 - currentTime) / 1000));
        throw new HTTPError(429, 'rate_limited', 'Observation request limit reached. Try again shortly.', retryAfter);
      }
      if (active >= maxConcurrentRequests) {
        throw new HTTPError(429, 'busy', 'Another observation is in progress. Try again shortly.', 2);
      }
      // Count authenticated attempts before parsing, and cap concurrent bodies as
      // well as model requests. All state is bounded to this server process.
      acceptedAt.push(currentTime);
      active++;
      ownsSlot = true;
      controllers.add(controller);
      if (!/^application\/json(?:\s*;\s*charset=utf-8)?$/iu.test(request.headers['content-type'] ?? '')
          || (request.headers['content-encoding'] && request.headers['content-encoding'] !== 'identity')) {
        throw new HTTPError(415, 'unsupported_media_type', 'Send uncompressed application/json.');
      }
      const declaredLength = request.headers['content-length'];
      if (declaredLength && Number(declaredLength) > LIMITS.maxBodyBytes) {
        throw new HTTPError(413, 'request_too_large', 'The request exceeds the 6 MiB limit.');
      }
      const input = validateRequest(await readBody(request), now() / 1000);
      if (controller.signal.aborted) return;
      const observation = await classify(input, { signal: controller.signal });
      if (!controller.signal.aborted) sendJSON(response, 200, validateObservation(observation, input));
    } catch (error) {
      const safe = error instanceof HTTPError ? error
        : new HTTPError(500, 'internal_error', 'The observation could not be processed. Continue manually.');
      sendJSON(response, safe.status, { error: { code: safe.code, message: safe.message } }, {
        Connection: 'close',
        ...(safe.retryAfter ? { 'Retry-After': String(safe.retryAfter) } : {}),
      });
    } finally {
      response.removeListener('close', onClose);
      if (ownsSlot) active--;
      controllers.delete(controller);
    }
  });
  server.abortObservations = () => { for (const controller of controllers) controller.abort(); };
  return server;
}
