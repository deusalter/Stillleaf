export class PublicationError extends Error {
  constructor(code, message) {
    super(message);
    this.name = "PublicationError";
    this.code = code;
  }
}
export const fail = (code, message) => {
  throw new PublicationError(code, message);
};
