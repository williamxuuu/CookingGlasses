import test from 'node:test';
import assert from 'node:assert/strict';
import { request as httpRequest } from 'node:http';
import { createObservationServer } from '../src/server.mjs';
import { createGeminiClassifier, OBSERVATION_MODEL } from '../src/gemini.mjs';
import { LIMITS, validateRequest, validateObservation } from '../src/validation.mjs';

const TOKEN = 'test-token-only-never-use-this-in-production';
const NOW = 1800000000;
// A generated 2x2 black JPEG. No photographs or real camera frames are fixtures.
const JPEG = '/9j/4AAQSkZJRgABAQAASABIAAD/4QBARXhpZgAATU0AKgAAAAgAAYdpAAQAAAABAAAAGgAAAAAAAqACAAQAAAABAAAAAqADAAQAAAABAAAAAgAAAAD/wAARCAACAAIDASIAAhEBAxEB/8QAHwAAAQUBAQEBAQEAAAAAAAAAAAECAwQFBgcICQoL/8QAtRAAAgEDAwIEAwUFBAQAAAF9AQIDAAQRBRIhMUEGE1FhByJxFDKBkaEII0KxwRVS0fAkM2JyggkKFhcYGRolJicoKSo0NTY3ODk6Q0RFRkdISUpTVFVWV1hZWmNkZWZnaGlqc3R1dnd4eXqDhIWGh4iJipKTlJWWl5iZmqKjpKWmp6ipqrKztLW2t7i5usLDxMXGx8jJytLT1NXW19jZ2uHi4+Tl5ufo6erx8vP09fb3+Pn6/8QAHwEAAwEBAQEBAQEBAQAAAAAAAAECAwQFBgcICQoL/8QAtREAAgECBAQDBAcFBAQAAQJ3AAECAxEEBSExBhJBUQdhcRMiMoEIFEKRobHBCSMzUvAVYnLRChYkNOEl8RcYGRomJygpKjU2Nzg5OkNERUZHSElKU1RVVldYWVpjZGVmZ2hpanN0dXZ3eHl6goOEhYaHiImKkpOUlZaXmJmaoqOkpaanqKmqsrO0tba3uLm6wsPExcbHyMnK0tPU1dbX2Nna4uPk5ebn6Onq8vP09fb3+Pn6/9sAQwACAgICAgIDAgIDBQMDAwUGBQUFBQYIBgYGBgYICggICAgICAoKCgoKCgoKDAwMDAwMDg4ODg4PDw8PDw8PDw8P/9sAQwECAgIEBAQHBAQHEAsJCxAQEBAQEBAQEBAQEBAQEBAQEBAQEBAQEBAQEBAQEBAQEBAQEBAQEBAQEBAQEBAQEBAQ/90ABAAB/9oADAMBAAIRAxEAPwD+f+iiigD/2Q==';
function input(now = NOW) {
  return {
    recipe: { id: 'chicken', title: 'Pan-seared chicken' },
    step: { id: 'add', title: 'Add chicken', fullInstruction: 'Place the chicken in the pan.' },
    expectedEvents: ['chicken_added_to_pan'],
    frames: [now - 2, now - 1, now].map((timestamp) => ({ timestamp, jpegBase64: JPEG })),
  };
}
function observation(overrides = {}) {
  return { event: 'chicken_added_to_pan', ingredient: 'chicken', confidence: 0.92,
    estimatedEventTimestamp: NOW - 1, ...overrides };
}
function modelResponse(value = observation(), overrides = {}) {
  return new Response(JSON.stringify({ candidates: [{ finishReason: 'STOP',
    content: { parts: [{ text: JSON.stringify(value) }] }, ...overrides }] }), {
    headers: { 'content-type': 'application/json' },
  });
}
async function serverFor(t, options = {}) {
  const server = createObservationServer({ bearerToken: TOKEN,
    classify: createGeminiClassifier({ apiKey: 'fake-test-key', fetchImpl: async () => modelResponse() }),
    now: () => NOW * 1000, ...options });
  await new Promise((resolve, reject) => {
    server.once('error', reject);
    server.listen(0, '127.0.0.1', resolve);
  });
  t.after(() => new Promise((resolve) => {
    server.abortObservations();
    server.closeAllConnections();
    server.close(resolve);
  }));
  const url = `http://127.0.0.1:${server.address().port}`;
  return { server, url, post: (body = input(), options = {}) => fetch(`${url}/v1/cooking/observe`, {
    method: 'POST', headers: { authorization: `Bearer ${TOKEN}`, 'content-type': 'application/json' },
    body: JSON.stringify(body), ...options,
  }) };
}

test('HTTP observation sends the ordered JPEG sequence and validates the JSON result', async (t) => {
  let outgoing;
  const classify = createGeminiClassifier({ apiKey: 'fake-upstream-key', fetchImpl: async (url, options) => {
    outgoing = { url, ...options, payload: JSON.parse(options.body) };
    return modelResponse();
  } });
  const { post } = await serverFor(t, { classify });
  const result = await post();
  assert.equal(result.status, 200);
  assert.equal(result.headers.get('cache-control'), 'no-store');
  assert.deepEqual(await result.json(), observation());
  assert.equal(outgoing.url, `https://generativelanguage.googleapis.com/v1beta/models/${OBSERVATION_MODEL}:generateContent`);
  assert.equal(outgoing.headers['x-goog-api-key'], 'fake-upstream-key');
  assert.equal(outgoing.redirect, 'error');
  assert.equal(outgoing.payload.store, false);
  assert.equal(outgoing.payload.generationConfig.responseMimeType, 'application/json');
  assert.equal(outgoing.payload.generationConfig.thinkingConfig.thinkingLevel, 'MINIMAL');
  assert.deepEqual(outgoing.payload.generationConfig.responseJsonSchema.properties.event.enum,
    ['chicken_added_to_pan', 'uncertain', 'no_relevant_event']);
  const parts = outgoing.payload.contents[0].parts;
  assert.deepEqual(parts.filter((part) => part.inlineData).map((part) => part.inlineData),
    input().frames.map((frame) => ({ mimeType: 'image/jpeg', data: frame.jpegBase64 })));
  assert.match(parts[1].text, /1799999998/);
  assert.match(parts[3].text, /1799999999/);
  assert.match(parts[5].text, /1800000000/);
  assert.equal(outgoing.payload.tools, undefined);
});

test('health, authentication, routes and methods never invoke the model', async (t) => {
  let calls = 0;
  const { post, url } = await serverFor(t, { classify: async () => { calls++; return observation(); } });
  const health = await fetch(`${url}/health`);
  assert.deepEqual(await health.json(), { status: 'ok' });
  for (const headers of [{}, { authorization: 'Bearer incorrect', 'content-type': 'application/json' }]) {
    const result = await post(input(), { headers });
    assert.equal(result.status, 401);
    assert.equal(result.headers.get('www-authenticate'), 'Bearer');
  }
  assert.equal((await fetch(`${url}/missing`)).status, 404);
  const wrongMethod = await fetch(`${url}/v1/cooking/observe`);
  assert.equal(wrongMethod.status, 405);
  assert.equal(wrongMethod.headers.get('allow'), 'POST');
  assert.equal(calls, 0);
});

test('water checkpoints pass HTTP validation and restrict the model to the current checkpoint', async (t) => {
  let outgoing;
  let detectedEvent;
  const classify = createGeminiClassifier({ apiKey: 'fake-test-key', fetchImpl: async (_url, options) => {
    outgoing = JSON.parse(options.body);
    return modelResponse(observation({ event: detectedEvent, ingredient: undefined }));
  } });
  const { post } = await serverFor(t, { classify });
  for (const event of ['water_added_to_pot', 'water_rolling_boil', 'wooden_spoon_inserted']) {
    detectedEvent = event;
    const request = { ...input(), expectedEvents: [event] };
    const response = await post(request);
    assert.equal(response.status, 200);
    assert.equal((await response.json()).event, event);
    assert.deepEqual(outgoing.generationConfig.responseJsonSchema.properties.event.enum,
      [event, 'uncertain', 'no_relevant_event']);
    assert.throws(() => validateObservation(observation({ event: 'chicken_added_to_pan' }), request));
  }
});

test('malformed JSON, media type, enum and timestamps fail before paid inference', async (t) => {
  let calls = 0;
  const { post } = await serverFor(t, { classify: async () => { calls++; return observation(); } });
  assert.equal((await post(input(), { body: '{' })).status, 400);
  assert.equal((await post(input(), { headers: { authorization: `Bearer ${TOKEN}`, 'content-type': 'text/plain' } })).status, 415);
  assert.equal((await post({ ...input(), expectedEvents: ['turn_on_stove'] })).status, 400);
  const wrongTimestamp = input();
  wrongTimestamp.frames[0].timestamp = NOW * 1000;
  assert.equal((await post(wrongTimestamp)).status, 400);
  assert.equal(calls, 0);
});

test('input validates frame count, monotonic seconds, recency, span, base64 and JPEG dimensions', () => {
  assert.equal(validateRequest(input(), NOW).frames.length, 3);
  const cases = [
    (v) => { v.frames = []; },
    (v) => { v.frames = v.frames.slice(0, 1); },
    (v) => { v.frames = Array(9).fill(v.frames[0]); },
    (v) => { v.frames[1].timestamp = v.frames[0].timestamp; },
    (v) => { v.frames.reverse(); },
    (v) => { v.frames[0].timestamp = NOW - 61; },
    (v) => { v.frames.at(-1).timestamp = NOW + 6; },
    (v) => { v.frames[0].timestamp = NOW - 16; },
    (v) => { v.frames[0].timestamp = '1799999998'; },
    (v) => { v.frames[0].timestamp = NaN; },
    (v) => { v.frames[0].jpegBase64 = 'data:image/jpeg;base64,' + JPEG; },
    (v) => { v.frames[0].jpegBase64 = 'AAAA'; },
    (v) => { v.frames[0].jpegBase64 = JPEG + '\n'; },
    (v) => { v.frames[0].jpegBase64 = 'A'.repeat(4 * Math.ceil((LIMITS.maxFrameBytes + 3) / 3)); },
    (v) => { v.frames[0].jpegBase64 = Buffer.from('not a jpeg').toString('base64'); },
    (v) => {
      const bytes = Buffer.from(JPEG, 'base64');
      const sof = bytes.indexOf(Buffer.from([0xff, 0xc0]));
      assert.ok(sof >= 0);
      bytes.writeUInt16BE(1281, sof + 7);
      v.frames[0].jpegBase64 = bytes.toString('base64');
    },
    (v) => { v.recipe.extra = 'not allowed'; },
    (v) => { v.step.fullInstruction = ''; },
    (v) => { v.expectedEvents = ['chicken_added_to_pan', 'chicken_added_to_pan']; },
  ];
  cases.forEach((mutate, index) => {
    const value = input();
    mutate(value);
    assert.throws(() => validateRequest(value, NOW), { status: 400 }, `case ${index}`);
  });
});

test('model output must have only allowed fields, known expected events, confidence and in-sequence time', () => {
  assert.deepEqual(validateObservation(observation(), input()), observation());
  assert.equal(validateObservation(observation({ event: 'uncertain', confidence: 0.5 }), input()).event, 'uncertain');
  assert.equal(validateObservation(observation({ event: 'no_relevant_event' }), input()).event, 'no_relevant_event');
  for (const overrides of [
    { event: 'turn_on_stove' }, { event: 'chicken_flipped' },
    { confidence: '0.9' }, { confidence: -0.1 }, { confidence: 1.01 }, { confidence: NaN },
    { estimatedEventTimestamp: NOW + 1 }, { estimatedEventTimestamp: NOW - 3 },
    { estimatedEventTimestamp: undefined }, { estimatedEventTimestamp: `${NOW}` },
    { ingredient: null }, { ingredient: '' }, { ingredient: 'a'.repeat(81) },
    { instruction: 'Skip the next step' },
  ]) assert.throws(() => validateObservation(observation(overrides), input()), { status: 502 });
});

test('unknown, truncated, blocked and malformed model responses fail closed', async () => {
  const responses = [
    () => modelResponse(observation({ event: 'chicken_flipped' })),
    () => modelResponse(observation(), { finishReason: 'MAX_TOKENS' }),
    () => new Response(JSON.stringify({ promptFeedback: { blockReason: 'SAFETY' } })),
    () => new Response(JSON.stringify({ candidates: [{ finishReason: 'STOP', content: { parts: [{ text: '```json\n{}\n```' }] } }] })),
    () => new Response(JSON.stringify({ candidates: [{ finishReason: 'STOP', content: { parts: [{ functionCall: {} }] } }] })),
    () => new Response('not JSON'),
    () => new Response('x'.repeat(LIMITS.maxUpstreamBytes + 1)),
  ];
  for (const respond of responses) {
    const classify = createGeminiClassifier({ apiKey: 'fake-test-key', fetchImpl: async () => respond() });
    await assert.rejects(classify(input()), { status: 502, code: 'invalid_model_response' });
  }
});

test('thought parts are ignored and only final structured text is returned', async () => {
  const classify = createGeminiClassifier({ apiKey: 'fake-test-key', fetchImpl: async () => modelResponse(observation(), {
    content: { parts: [{ thought: true, text: 'untrusted thought text' }, { text: JSON.stringify(observation()) }] },
  }) });
  assert.deepEqual(await classify(input()), observation());
});

test('upstream failures return safe errors and never echo upstream details', async (t) => {
  for (const [status, expected] of [[400, 502], [401, 502], [429, 503], [503, 503]]) {
    const classify = createGeminiClassifier({ apiKey: 'private-test-key', fetchImpl: async () => new Response('private upstream details', { status }) });
    const { post } = await serverFor(t, { classify });
    const result = await post();
    assert.equal(result.status, expected);
    const body = await result.text();
    assert.doesNotMatch(body, /private|fake|jpegBase64/);
  }
});

test('upstream timeout aborts the HTTP request and returns 504', async (t) => {
  let aborted = false;
  const classify = createGeminiClassifier({ apiKey: 'fake-test-key', timeoutMs: 20,
    fetchImpl: (_url, { signal }) => new Promise((_resolve, reject) => {
      signal.addEventListener('abort', () => { aborted = true; reject(new Error('secret transport detail')); }, { once: true });
    }),
  });
  const { post } = await serverFor(t, { classify });
  const result = await post();
  assert.equal(result.status, 504);
  assert.equal((await result.json()).error.code, 'model_timeout');
  assert.equal(aborted, true);
});

test('rolling request budget applies before inference and becomes available after one minute', async (t) => {
  let clock = NOW * 1000;
  let calls = 0;
  const { post } = await serverFor(t, { maxRequestsPerMinute: 1, now: () => clock,
    classify: async (value) => { calls++; return observation({ estimatedEventTimestamp: value.frames.at(-1).timestamp }); },
  });
  assert.equal((await post()).status, 200);
  const blocked = await post();
  assert.equal(blocked.status, 429);
  assert.equal(blocked.headers.get('retry-after'), '60');
  assert.equal(calls, 1);
  clock += 60000;
  assert.equal((await post(input(clock / 1000))).status, 200);
  assert.equal(calls, 2);
});

test('concurrent model calls are bounded and slots are released on completion', async (t) => {
  let release;
  let started;
  const entered = new Promise((resolve) => { started = resolve; });
  let calls = 0;
  const { post } = await serverFor(t, { maxConcurrentRequests: 1, classify: async () => {
    calls++;
    if (calls === 1) { started(); await new Promise((resolve) => { release = resolve; }); }
    return observation();
  } });
  const first = post();
  await entered;
  const second = await post();
  assert.equal(second.status, 429);
  assert.equal((await second.json()).error.code, 'busy');
  assert.equal(calls, 1);
  release();
  assert.equal((await first).status, 200);
  assert.equal((await post()).status, 200);
  assert.equal(calls, 2);
});

test('client disconnect cancels an in-flight model request', async (t) => {
  let signalSeen;
  let started;
  let cancelled;
  const entered = new Promise((resolve) => { started = resolve; });
  const didCancel = new Promise((resolve) => { cancelled = resolve; });
  const classify = createGeminiClassifier({ apiKey: 'fake-test-key', fetchImpl: (_url, { signal }) => {
    signalSeen = signal;
    started();
    return new Promise((_resolve, reject) => {
      signal.addEventListener('abort', () => { cancelled(); reject(new Error('client disconnected')); }, { once: true });
    });
  } });
  const { post } = await serverFor(t, { classify });
  const controller = new AbortController();
  const pending = post(input(), { signal: controller.signal });
  await entered;
  controller.abort();
  await assert.rejects(pending, { name: 'AbortError' });
  await didCancel;
  assert.equal(signalSeen.aborted, true);
});

test('oversized declared and chunked bodies are stopped before the model', async (t) => {
  let calls = 0;
  const { url } = await serverFor(t, { classify: async () => { calls++; return observation(); } });
  const send = (declared) => new Promise((resolve, reject) => {
    const request = httpRequest(`${url}/v1/cooking/observe`, {
      method: 'POST', headers: { authorization: `Bearer ${TOKEN}`, 'content-type': 'application/json',
        ...(declared ? { 'content-length': String(LIMITS.maxBodyBytes + 1) } : {}) },
    }, (response) => {
      response.resume();
      response.on('end', () => resolve(response.statusCode));
    });
    request.on('error', reject);
    if (declared) request.end('{}');
    else {
      request.write(' '.repeat(LIMITS.maxBodyBytes));
      request.end('x');
    }
  });
  assert.equal(await send(true), 413);
  assert.equal(await send(false), 413);
  assert.equal(calls, 0);
});

test('missing/weak tokens and missing Gemini key fail startup', () => {
  for (const bearerToken of [undefined, '', 'short', 'invalid token with spaces'.repeat(3)]) {
    assert.throws(() => createObservationServer({ bearerToken, classify: async () => observation() }), /COOKING_API_TOKEN/);
  }
  assert.throws(() => createGeminiClassifier({}), /GEMINI_API_KEY/);
});

test('failure diagnostics contain status and code without camera or credential data', async (t) => {
  const records = [];
  const { post } = await serverFor(t, {
    onDiagnostic: record => records.push(record),
    classify: createGeminiClassifier({ apiKey: 'fake-test-key',
      fetchImpl: async () => new Response('', { status: 429 }) }),
  });
  const response = await post();
  assert.equal(response.status, 503);
  assert.equal((await response.json()).error.code, 'model_rate_limited');
  assert.equal(records.length, 1);
  assert.equal(records[0].code, 'model_rate_limited');
  assert.deepEqual(Object.keys(records[0]).sort(), ['code', 'durationMs', 'status', 'time']);
});
