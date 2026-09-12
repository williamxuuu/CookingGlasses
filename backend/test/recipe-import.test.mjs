import test from 'node:test';
import assert from 'node:assert/strict';
import { createRecipeImporter, validateImportRequest, validateImportedRecipe } from '../src/recipe-import.mjs';
import { createObservationServer } from '../src/server.mjs';

const url = 'https://example.com/recipe';
const recipe = () => ({ isRecipe: true, title: 'Yogurt dip', subtitle: 'Serves 2', ingredients: ['200 g yogurt', '1 tsp lemon juice'],
  steps: [{ title: 'Combine', instruction: 'Stir the yogurt and lemon juice together.', glassesInstruction: 'Mix yogurt and lemon.', timerSeconds: 0 }], notes: [] });
function response(value = recipe(), metadata = [{ retrievedUrl: url, urlRetrievalStatus: 'URL_RETRIEVAL_STATUS_SUCCESS' }], finishReason = 'STOP') {
  return new Response(JSON.stringify({ candidates: [{ finishReason,
    content: { parts: [{ text: JSON.stringify(value) }] }, urlContextMetadata: { urlMetadata: metadata } }] }));
}
test('reject ambiguous inputs, private URLs, credentials, unsupported URLs and malformed images', () => {
  for (const input of [{}, { url, jpegBase64: 'AA==' }, { url: 'http://example.com' }, { url: 'https://127.0.0.1/a' },
    { url: 'https://[::1]/' }, { url: 'https://kitchen.local/a' }, { url: 'https://user:secret@example.com/a' },
    { url: 'https://example.com:8787/a' }, { jpegBase64: 'not-an-image' }, { jpegBase64: 'A'.repeat(4 * 1024 * 1024 + 4) }]) {
    assert.throws(() => validateImportRequest(input), e => e.status === 400);
  }
  assert.deepEqual(validateImportRequest({ url: url + '#ingredients' }), { url });
});
test('URL imports require successful retrieval of the supplied page', async () => {
  for (const metadata of [[], [{ retrievedUrl: url, urlRetrievalStatus: 'URL_RETRIEVAL_STATUS_ERROR' }],
    [{ retrievedUrl: 'https://another.example/recipe', urlRetrievalStatus: 'URL_RETRIEVAL_STATUS_SUCCESS' }]]) {
    const importer = createRecipeImporter({ apiKey: 'test-key', fetchImpl: async () => response(recipe(), metadata) });
    await assert.rejects(importer({ url }), e => e.code === 'page_unavailable');
  }
  const importer = createRecipeImporter({ apiKey: 'test-key', fetchImpl: async () => response() });
  assert.equal((await importer({ url })).sourceURL, url);
});
const videoID = 'AbCdEf12_-3';
const videoURL = `https://www.youtube.com/watch?v=${videoID}`;
test('YouTube watch, mobile, share, Shorts and embed links identify one complete video', () => {
  for (const link of [videoURL, `https://youtube.com/watch?v=${videoID}&list=playlist&t=30`,
    `https://m.youtube.com/watch?v=${videoID}`, `https://youtu.be/${videoID}?si=tracking&t=30`,
    `https://www.youtube.com/shorts/${videoID}?feature=share`, `https://www.youtube.com/embed/${videoID}/`]) {
    const validated = validateImportRequest({ url: link });
    assert.deepEqual(validated, { url: videoURL });
    // Both the server and importer validate; normalization must be idempotent.
    assert.deepEqual(validateImportRequest(validated), validated);
  }
  for (const link of ['https://youtube.com/playlist?list=123', 'https://youtube.com/@cook',
    'https://youtube.com/watch?v=short', `https://youtube.com/watch?v=${videoID}&v=Other123456`,
    `https://youtu.be/${videoID}/extra`, 'https://youtube.com/redirect?q=https://example.com']) {
    assert.throws(() => validateImportRequest({ url: link }), e => e.status === 400);
  }
});
test('YouTube is supplied as video, with no webpage tool, while preserving the structured cooking draft', async () => {
  let calls = 0;
  const value = recipe();
  value.steps[0].timerSeconds = 30;
  value.notes = ['Oil quantity is not stated in the video.'];
  const importer = createRecipeImporter({ apiKey: 'test-key', fetchImpl: async (endpoint, options) => {
    calls++;
    assert.match(endpoint, /gemini-3\.6-flash:generateContent$/);
    const body = JSON.parse(options.body);
    assert.deepEqual(body.contents[0].parts[0], { fileData: { fileUri: videoURL } });
    assert.equal(body.tools, undefined);
    assert.equal(body.generationConfig.responseMimeType, 'application/json');
    assert.equal(body.generationConfig.thinkingConfig.thinkingLevel, 'LOW');
    assert.match(body.systemInstruction.parts[0].text, /BOTH the audio/);
    return response(value, []); // Video input does not return URL Context metadata.
  } });
  const result = await importer({ url: `https://youtu.be/${videoID}?t=10` });
  assert.deepEqual(result, { ...validateImportedRecipe(value), sourceURL: videoURL });
  assert.equal(calls, 1);
});
test('non-YouTube hosts stay on the page retrieval path and cannot bypass retrieval evidence', async () => {
  const importer = createRecipeImporter({ apiKey: 'test-key', fetchImpl: async (_, options) => {
    const body = JSON.parse(options.body);
    assert.deepEqual(body.tools, [{ url_context: {} }]);
    assert.ok(body.contents[0].parts.every(part => !part.fileData));
    return response(recipe(), []);
  } });
  for (const link of [url, `https://youtube.com.example.com/watch?v=${videoID}`, `https://example.com/?v=${videoID}`]) {
    await assert.rejects(importer({ url: link }), e => e.code === 'page_unavailable');
  }
});
test('inaccessible videos fail without a transcript-only or remembered-recipe fallback', async () => {
  let calls = 0;
  const importer = createRecipeImporter({ apiKey: 'test-key', fetchImpl: async () => {
    calls++;
    return new Response(JSON.stringify({ error: { message: 'Cannot access YouTube video: sensitive provider details' } }), { status: 400 });
  } });
  await assert.rejects(importer({ url: videoURL }), e => e.status === 422 && e.code === 'video_unavailable'
    && !e.message.includes('sensitive'));
  assert.equal(calls, 1);
  for (const [value, finish, code] of [[{ isRecipe: false }, 'STOP', 'not_a_recipe'],
    [recipe(), 'MAX_TOKENS', 'incomplete_recipe']]) {
    const rejectImport = createRecipeImporter({ apiKey: 'test-key', fetchImpl: async () => response(value, [], finish) });
    await assert.rejects(rejectImport({ url: videoURL }), e => e.code === code);
  }
  const badKey = createRecipeImporter({ apiKey: 'test-key', fetchImpl: async () =>
    new Response(JSON.stringify({ error: { message: 'API key not valid' } }), { status: 400 }) });
  await assert.rejects(badKey({ url: videoURL }), e => e.status === 502 && e.code === 'import_unavailable');
});
test('video deadline and cancellation abort upstream work', async () => {
  const waitingFetch = async (_, { signal }) => {
    // Keep the test event loop alive; AbortSignal.timeout itself is unreferenced.
    await new Promise((resolve, reject) => {
      const hold = setTimeout(resolve, 1000);
      const stop = () => { clearTimeout(hold); reject(signal.reason); };
      if (signal.aborted) stop(); else signal.addEventListener('abort', stop, { once: true });
    });
    return response(recipe(), []);
  };
  const timed = createRecipeImporter({ apiKey: 'test-key', videoTimeoutMs: 10, fetchImpl: waitingFetch });
  await assert.rejects(timed({ url: videoURL }), e => e.status === 504 && /shorter video/.test(e.message));
  const controller = new AbortController();
  const cancelled = createRecipeImporter({ apiKey: 'test-key', fetchImpl: waitingFetch });
  const pending = cancelled({ url: videoURL }, { signal: controller.signal });
  controller.abort();
  await assert.rejects(pending, e => e.code === 'cancelled');
});
test('reject invented empty recipes, out-of-range timers and truncated output', async () => {
  for (const bad of [{ ...recipe(), steps: [] }, { ...recipe(), ingredients: [] },
    { ...recipe(), steps: [{ ...recipe().steps[0], timerSeconds: -1 }] },
    { ...recipe(), steps: [{ ...recipe().steps[0], timerSeconds: 86401 }] }]) {
    assert.throws(() => validateImportedRecipe(bad), e => e.code === 'invalid_recipe');
  }
  assert.throws(() => validateImportedRecipe({ isRecipe: false }), e => e.code === 'not_a_recipe');
  const importer = createRecipeImporter({ apiKey: 'test-key', fetchImpl: async () => response(recipe(), undefined, 'MAX_TOKENS') });
  await assert.rejects(importer({ url }), e => e.code === 'incomplete_recipe');
});
test('cancelled requests stop upstream work without exposing errors', async () => {
  const controller = new AbortController(); controller.abort();
  const importer = createRecipeImporter({ apiKey: 'test-key', fetchImpl: async (_, options) => {
    options.signal.throwIfAborted(); throw new Error('sensitive upstream detail');
  } });
  await assert.rejects(importer({ url }, { signal: controller.signal }), e => e.code === 'cancelled' && !e.message.includes('sensitive'));
});
test('model overload and quota exhaustion return distinct actionable errors', async () => {
  for (const [status, code, message] of [[503, 'import_unavailable', /high demand/], [429, 'import_rate_limited', /usage limit/]]) {
    const importer = createRecipeImporter({ apiKey: 'test-key', fetchImpl: async () => new Response('upstream private details', { status }) });
    await assert.rejects(importer({ url }), e => e.status === status && e.code === code && message.test(e.message)
      && !e.message.includes('private'));
  }
});
test('import endpoint shares authentication and rate limiting with observations', async t => {
  const token = 'test-only-backend-token-1234567890'; let calls = 0;
  const server = createObservationServer({ bearerToken: token, classify: async () => {},
    importRecipe: async () => { calls++; return { ...validateImportedRecipe(recipe()), sourceURL: url }; }, maxRequestsPerMinute: 1 });
  await new Promise(resolve => server.listen(0, '127.0.0.1', resolve));
  t.after(() => { server.closeAllConnections(); server.close(); });
  const post = (accessToken, body = { url }) => fetch(`http://127.0.0.1:${server.address().port}/v1/recipes/import`, {
    method: 'POST', headers: { authorization: `Bearer ${accessToken}`, 'content-type': 'application/json' }, body: JSON.stringify(body) });
  assert.equal((await post('wrong')).status, 401); assert.equal(calls, 0);
  const accepted = await post(token); assert.equal(accepted.status, 200); assert.equal((await accepted.json()).title, 'Yogurt dip');
  assert.equal((await post(token)).status, 429); assert.equal(calls, 1);
});
