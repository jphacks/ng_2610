import { GetObjectCommand, PutObjectCommand, S3Client } from "@aws-sdk/client-s3";

export function createRegionalStateStore({ bucket, client = new S3Client({}) }) {
  if (!bucket) throw new Error("Missing regional state bucket");
  const object = { Bucket: bucket, Key: "regional-monitor.json" };
  let etag;

  return {
    async load() {
      let result;
      try {
        result = await client.send(new GetObjectCommand(object));
      } catch (error) {
        if (error.name !== "NoSuchKey") throw error;
        etag = null;
        return null;
      }
      const snapshot = JSON.parse(await result.Body.transformToString());
      if (!result.ETag || snapshot?.version !== 1 || !snapshot.records ||
          typeof snapshot.records !== "object" || Array.isArray(snapshot.records)) {
        throw new Error("Invalid regional state snapshot");
      }
      etag = result.ETag;
      return snapshot;
    },

    async save(snapshot) {
      if (etag === undefined) throw new Error("Load regional state before saving");
      const result = await client.send(new PutObjectCommand({
        ...object,
        Body: JSON.stringify(snapshot),
        ContentType: "application/json",
        ...(etag === null ? { IfNoneMatch: "*" } : { IfMatch: etag }),
      }));
      if (!result.ETag) throw new Error("Missing regional state ETag");
      etag = result.ETag;
    },
  };
}
