// Only snapshots created here can bypass reactive property reads. In particular,
// a frozen object supplied by a caller can still contain getters or be a Proxy.
const snapshots = new WeakSet();

export function isScalarRecord(value) {
  return snapshots.has(value);
}

export function scalarRecord(fields) {
  if (isScalarRecord(fields)) return fields;
  if (fields === null || typeof fields !== "object" || Array.isArray(fields)) {
    throw new TypeError("scalarRecord expects an object of finite numbers and strings.");
  }
  const record = Object.create(null);
  for (const name of Reflect.ownKeys(fields)) {
    const field = Object.getOwnPropertyDescriptor(fields, name);
    if (!field?.enumerable) continue;
    if (typeof name !== "string" || !Object.hasOwn(field, "value") ||
        (typeof field.value !== "string" && !Number.isFinite(field.value))) {
      throw new TypeError("Scalar fields must be own data properties containing finite numbers or strings.");
    }
    record[name] = field.value;
  }
  Object.freeze(record);
  snapshots.add(record);
  return record;
}
