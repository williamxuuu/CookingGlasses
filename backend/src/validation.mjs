import { invalidRequest, invalidUpstream } from './errors.mjs';

export const EVENTS = Object.freeze([
  'chicken_added_to_pan',
  'chicken_flipped',
  'chicken_removed_from_pan',
  'pot_placed_on_stove',
  'pasta_added_to_water',
  'ingredient_added',
  'uncertain',
  'no_relevant_event',
]);

export const LIMITS = Object.freeze({
  minFrames: 2,
  maxFrames: 8,
  maxFrameBytes: 512 * 1024,
  maxImageDimension: 1280,
  maxBodyBytes: 6 * 1024 * 1024,
  maxSequenceSeconds: 15,
  maxFrameAgeSeconds: 60,
  maxFutureSeconds: 5,
  maxUpstreamBytes: 64 * 1024,
  bodyTimeoutMs: 10000,
});

function object(value, keys, fail) {
  if (!value || typeof value !== 'object' || Array.isArray(value)
      || Object.keys(value).some((key) => !keys.includes(key))) throw fail();
}

function text(value, maxLength, fail) {
  if (typeof value !== 'string' || value.trim().length === 0 || value.length > maxLength
      || /[\u0000-\u0008\u000b\u000c\u000e-\u001f\u007f]/u.test(value)) throw fail();
  return value;
}

function finite(value) {
  return typeof value === 'number' && Number.isFinite(value);
}

// Inspect the JPEG header without retaining or decoding image pixels. This is a
// bounded format/dimension sanity check; the model provider still decodes it.
export function validJPEGHeader(bytes, maximumDimension = LIMITS.maxImageDimension) {
  if (bytes.length < 12 || bytes[0] !== 0xff || bytes[1] !== 0xd8
      || bytes.at(-2) !== 0xff || bytes.at(-1) !== 0xd9) return false;
  let offset = 2;
  let hasDimensions = false;
  while (offset + 4 <= bytes.length) {
    if (bytes[offset++] !== 0xff) return false;
    while (bytes[offset] === 0xff) offset++;
    const marker = bytes[offset++];
    if (marker === 0xda) return hasDimensions; // Start of scan.
    if (marker === 0x00 || marker === 0xd8 || marker === 0xd9) return false;
    if (marker === 0x01 || (marker >= 0xd0 && marker <= 0xd7)) continue;
    if (offset + 2 > bytes.length) return false;
    const length = bytes.readUInt16BE(offset);
    if (length < 2 || offset + length > bytes.length) return false;
    const isStartOfFrame = marker >= 0xc0 && marker <= 0xcf
      && ![0xc4, 0xc8, 0xcc].includes(marker);
    if (isStartOfFrame) {
      if (length < 8) return false;
      const height = bytes.readUInt16BE(offset + 3);
      const width = bytes.readUInt16BE(offset + 5);
      if (width === 0 || height === 0 || width > maximumDimension
          || height > maximumDimension) return false;
      hasDimensions = true;
    }
    offset += length;
  }
  return false;
}

export function validateRequest(value, nowSeconds = Date.now() / 1000) {
  const bad = () => invalidRequest('Request fields do not match the observation contract.');
  object(value, ['recipe', 'step', 'expectedEvents', 'frames'], bad);
  object(value.recipe, ['id', 'title'], bad);
  object(value.step, ['id', 'title', 'fullInstruction'], bad);
  text(value.recipe.id, 100, bad);
  text(value.recipe.title, 200, bad);
  text(value.step.id, 100, bad);
  text(value.step.title, 200, bad);
  text(value.step.fullInstruction, 2000, bad);
  if (!Array.isArray(value.expectedEvents) || value.expectedEvents.length > EVENTS.length
      || value.expectedEvents.some((event) => !EVENTS.includes(event))
      || new Set(value.expectedEvents).size !== value.expectedEvents.length) throw bad();
  if (!Array.isArray(value.frames) || value.frames.length < LIMITS.minFrames
      || value.frames.length > LIMITS.maxFrames) {
    throw invalidRequest(`Provide ${LIMITS.minFrames}–${LIMITS.maxFrames} frames.`);
  }
  let previous = -Infinity;
  for (const frame of value.frames) {
    object(frame, ['timestamp', 'jpegBase64'], bad);
    if (!finite(frame.timestamp) || frame.timestamp <= 0
        || frame.timestamp <= previous
        || frame.timestamp < nowSeconds - LIMITS.maxFrameAgeSeconds
        || frame.timestamp > nowSeconds + LIMITS.maxFutureSeconds) {
      throw invalidRequest('Frames must have recent, strictly increasing Unix timestamps in seconds.');
    }
    previous = frame.timestamp;
    if (typeof frame.jpegBase64 !== 'string' || frame.jpegBase64.length === 0
        || frame.jpegBase64.length > Math.ceil(LIMITS.maxFrameBytes / 3) * 4
        || !/^(?:[A-Za-z0-9+/]{4})*(?:[A-Za-z0-9+/]{2}==|[A-Za-z0-9+/]{3}=)?$/u.test(frame.jpegBase64)) {
      throw invalidRequest('Frames must contain canonical base64 JPEGs of at most 512 KiB.');
    }
    const bytes = Buffer.from(frame.jpegBase64, 'base64');
    if (bytes.length > LIMITS.maxFrameBytes || bytes.toString('base64') !== frame.jpegBase64
        || !validJPEGHeader(bytes)) {
      throw invalidRequest('Each frame must be a JPEG of at most 512 KiB and 1280 pixels per dimension.');
    }
  }
  if (value.frames.at(-1).timestamp - value.frames[0].timestamp > LIMITS.maxSequenceSeconds) {
    throw invalidRequest('The frame sequence must span at most 15 seconds.');
  }
  return value;
}

export function validateObservation(value, request) {
  const bad = invalidUpstream;
  object(value, ['event', 'ingredient', 'confidence', 'estimatedEventTimestamp'], bad);
  if (!EVENTS.includes(value.event)
      || ![...request.expectedEvents, 'uncertain', 'no_relevant_event'].includes(value.event)
      || !finite(value.confidence) || value.confidence < 0 || value.confidence > 1
      || !finite(value.estimatedEventTimestamp)
      || value.estimatedEventTimestamp < request.frames[0].timestamp
      || value.estimatedEventTimestamp > request.frames.at(-1).timestamp) throw bad();
  if (value.ingredient !== undefined) text(value.ingredient, 80, bad);
  return {
    event: value.event,
    ...(value.ingredient === undefined ? {} : { ingredient: value.ingredient }),
    confidence: value.confidence,
    estimatedEventTimestamp: value.estimatedEventTimestamp,
  };
}

export function observationSchema(request) {
  return {
    type: 'object',
    additionalProperties: false,
    properties: {
      event: { type: 'string', enum: [...new Set([...request.expectedEvents, 'uncertain', 'no_relevant_event'])] },
      ingredient: { type: 'string', maxLength: 80, description: 'Optional ingredient if visually identifiable. Omit when unknown.' },
      confidence: { type: 'number', minimum: 0, maximum: 1 },
      estimatedEventTimestamp: {
        type: 'number',
        minimum: request.frames[0].timestamp,
        maximum: request.frames.at(-1).timestamp,
        description: 'Unix seconds at the earliest frame that provides clear evidence of the transition.',
      },
    },
    required: ['event', 'confidence', 'estimatedEventTimestamp'],
  };
}
