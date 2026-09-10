export class HTTPError extends Error {
  constructor(status, code, message, retryAfter) {
    super(message);
    this.status = status;
    this.code = code;
    this.retryAfter = retryAfter;
  }
}

export const invalidRequest = (message) => new HTTPError(400, 'invalid_request', message);
export const invalidUpstream = () => new HTTPError(502, 'invalid_model_response', 'The observation could not be validated. Try again or continue manually.');
