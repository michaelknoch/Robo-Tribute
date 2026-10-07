#!/bin/bash
# Seeds the disposable test mongod used by ShellTests and SnapshotTests (never point this at a real server).
set -euo pipefail
PORT="${ROBO3T_TEST_PORT:-27999}"
mongosh --quiet --host 127.0.0.1 --port "$PORT" --eval '
const s = db.getSiblingDB("sample");
s.dropDatabase();
s.people.insertOne({
  _id: "doc-0001", name: "Ada Lovelace", description: "First programmer", slug: "ada-lovelace", public: true,
  tags: ["tag-a", "tag-b"], level: 3, price: 9.99, count: NumberLong("1234567890123"), dec: NumberDecimal("1.50"),
  created: new Date("2016-07-21T14:07:09Z"), uuid: UUID("0123456789abcdef0123456789abcdef"),
  i18n: { zh: { name: "你好世界" }, de: { name: "Hallo Welt" } }, nothing: null, re: /abc/i
});
const docs = [];
for (let i = 0; i < 120; i++) docs.push({ n: i, title: "record " + i, tags: ["a", "b"], points: [{ x: i, y: 2 }, { x: 3, y: 4 }] });
s.records.insertMany(docs);
s.records.createIndex({ n: 1 });
s.users.insertOne({ email: "user@example.com", createdAt: new Date() });
print("seeded", s.getCollectionNames().join(", "));
'
