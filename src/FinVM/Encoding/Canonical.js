import { createHash } from "node:crypto";

export const sha256String = (input) =>
  createHash("sha256").update(input, "utf8").digest("hex");
