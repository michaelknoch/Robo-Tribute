// Robo Tribute shell: the legacy `mongo` shell API, implemented on top of modern
// MongoDB commands (OP_MSG) so it works against MongoDB 3.6 through 8.x.
(function (global) {
    'use strict';
    var N = global.__native;

    // ------------------------------------------------------------------ BSON types

    function ObjectId(hex) {
        if (!(this instanceof ObjectId)) return new ObjectId(hex);
        if (hex === undefined || hex === null) hex = N.newObjectId();
        if (hex instanceof ObjectId) hex = hex.str;
        if (typeof hex !== 'string' || !/^[0-9a-fA-F]{24}$/.test(hex))
            throw new Error('invalid object id: length');
        this.str = hex.toLowerCase();
    }
    ObjectId.prototype.toString = function () { return 'ObjectId("' + this.str + '")'; };
    ObjectId.prototype.tojson = ObjectId.prototype.toString;
    ObjectId.prototype.valueOf = function () { return this.str; };
    ObjectId.prototype.toHexString = function () { return this.str; };
    ObjectId.prototype.getTimestamp = function () { return new Date(parseInt(this.str.substr(0, 8), 16) * 1000); };
    ObjectId.prototype.equals = function (o) { return o instanceof ObjectId && o.str === this.str; };
    ObjectId.fromDate = function (d) {
        var seconds = Math.floor(d.getTime() / 1000).toString(16);
        while (seconds.length < 8) seconds = '0' + seconds;
        return new ObjectId(seconds + '0000000000000000');
    };

    function ISODate(s) {
        if (s === undefined) return new Date();
        if (s instanceof Date) return new Date(s.getTime());
        if (typeof s === 'number') return new Date(s);
        var ms = N.parseISODate(String(s));
        if (ms === null || ms === undefined) throw new Error('invalid ISO date: ' + s);
        return new Date(ms);
    }

    function NumberLong(v) {
        if (!(this instanceof NumberLong)) return new NumberLong(v);
        if (v === undefined) v = 0;
        if (v instanceof NumberLong) v = v.str;
        var s = typeof v === 'number' ? String(Math.trunc(v)) : String(v).trim();
        if (!/^-?\d+$/.test(s)) throw new Error('could not convert "' + v + '" to NumberLong');
        this.str = s.replace(/^(-?)0+(\d)/, '$1$2');
    }
    NumberLong.prototype.valueOf = function () { return Number(this.str); };
    NumberLong.prototype.toNumber = NumberLong.prototype.valueOf;
    NumberLong.prototype.toString = function () {
        var n = Number(this.str);
        return Number.isSafeInteger(n) ? 'NumberLong(' + this.str + ')' : 'NumberLong("' + this.str + '")';
    };
    NumberLong.prototype.tojson = NumberLong.prototype.toString;
    Object.defineProperty(NumberLong.prototype, 'floatApprox', { get: function () { return Number(this.str); } });

    function NumberInt(v) {
        if (!(this instanceof NumberInt)) return new NumberInt(v);
        this.value = v === undefined ? 0 : (Number(v) | 0);
    }
    NumberInt.prototype.valueOf = function () { return this.value; };
    NumberInt.prototype.toNumber = NumberInt.prototype.valueOf;
    NumberInt.prototype.toString = function () { return 'NumberInt(' + this.value + ')'; };
    NumberInt.prototype.tojson = NumberInt.prototype.toString;

    function NumberDecimal(v) {
        if (!(this instanceof NumberDecimal)) return new NumberDecimal(v);
        this.str = v === undefined ? '0' : String(v);
    }
    NumberDecimal.prototype.valueOf = function () { return Number(this.str); };
    NumberDecimal.prototype.toString = function () { return 'NumberDecimal("' + this.str + '")'; };
    NumberDecimal.prototype.tojson = NumberDecimal.prototype.toString;

    function Timestamp(t, i) {
        if (!(this instanceof Timestamp)) return new Timestamp(t, i);
        this.t = t === undefined ? 0 : Number(t);
        this.i = i === undefined ? 0 : Number(i);
    }
    Timestamp.prototype.getTime = function () { return this.t; };
    Timestamp.prototype.getInc = function () { return this.i; };
    Timestamp.prototype.toString = function () { return 'Timestamp(' + this.t + ', ' + this.i + ')'; };
    Timestamp.prototype.tojson = Timestamp.prototype.toString;

    function BinData(type, base64) {
        if (!(this instanceof BinData)) return new BinData(type, base64);
        this.type = Number(type);
        this.base64 = String(base64);
    }
    BinData.prototype.subtype = function () { return this.type; };
    BinData.prototype.length = function () { return N.base64ToHex(this.base64).length / 2; };
    BinData.prototype.hex = function () { return N.base64ToHex(this.base64); };
    BinData.prototype.toString = function () {
        if (this.type === 4) return 'UUID("' + formatUUID(this.hex()) + '")';
        return 'BinData(' + this.type + ',"' + this.base64 + '")';
    };
    BinData.prototype.tojson = BinData.prototype.toString;

    function formatUUID(hex) {
        return hex.substr(0, 8) + '-' + hex.substr(8, 4) + '-' + hex.substr(12, 4) + '-' + hex.substr(16, 4) + '-' + hex.substr(20, 12);
    }
    function HexData(type, hex) { return new BinData(type, N.hexToBase64(String(hex))); }
    function UUID(s) {
        var hex = s === undefined ? N.randomUUIDHex() : String(s).replace(/-/g, '');
        if (!/^[0-9a-fA-F]{32}$/.test(hex)) throw new Error('UUID string must have 32 hex characters');
        return new BinData(4, N.hexToBase64(hex));
    }
    function legacyUUID(encoding) {
        return function (s) {
            var hex = String(s).replace(/-/g, '');
            if (!/^[0-9a-fA-F]{32}$/.test(hex)) throw new Error('UUID string must have 32 hex characters');
            return new BinData(3, N.legacyUUIDToBase64(hex, encoding));
        };
    }
    function MD5(hex) { return new BinData(5, N.hexToBase64(String(hex))); }

    function MinKeyType() {}
    MinKeyType.prototype.toString = function () { return '{ "$minKey" : 1 }'; };
    MinKeyType.prototype.tojson = MinKeyType.prototype.toString;
    function MaxKeyType() {}
    MaxKeyType.prototype.toString = function () { return '{ "$maxKey" : 1 }'; };
    MaxKeyType.prototype.tojson = MaxKeyType.prototype.toString;
    var MinKey = new MinKeyType();
    var MaxKey = new MaxKeyType();

    function DBRef(ns, id, dbName) {
        if (!(this instanceof DBRef)) return new DBRef(ns, id, dbName);
        this.$ref = ns;
        this.$id = id;
        if (dbName !== undefined) this.$db = dbName;
    }
    DBRef.prototype.getCollection = function () { return this.$ref; };
    DBRef.prototype.getId = function () { return this.$id; };
    DBRef.prototype.getDb = function () { return this.$db; };
    DBRef.prototype.toString = function () { return 'DBRef("' + this.$ref + '", ' + tojson(this.$id) + ')'; };
    DBRef.prototype.tojson = DBRef.prototype.toString;
    var DBPointer = DBRef;

    function Code(code, scope) {
        if (!(this instanceof Code)) return new Code(code, scope);
        this.code = typeof code === 'function' ? code.toString() : String(code);
        if (scope !== undefined) this.scope = scope;
    }
    Code.prototype.toString = function () { return this.code; };

    // ------------------------------------------------------------------ Extended JSON

    function isPlainObject(v) {
        if (v === null || typeof v !== 'object') return false;
        var proto = Object.getPrototypeOf(v);
        return proto === Object.prototype || proto === null;
    }

    function toExt(v) {
        if (v === undefined) return { $undefined: true };
        if (v === null) return null;
        switch (typeof v) {
            case 'boolean': return v;
            case 'string': return v;
            case 'number':
                if (Number.isInteger(v) && v >= -2147483648 && v <= 2147483647 && !(v === 0 && 1 / v < 0))
                    return { $numberInt: String(v) };
                if (isNaN(v)) return { $numberDouble: 'NaN' };
                if (v === Infinity) return { $numberDouble: 'Infinity' };
                if (v === -Infinity) return { $numberDouble: '-Infinity' };
                return { $numberDouble: String(v) };
            case 'bigint': return { $numberLong: v.toString() };
            case 'function': return { $code: v.toString() };
            case 'symbol': return { $symbol: v.toString() };
        }
        if (v instanceof ObjectId) return { $oid: v.str };
        if (v instanceof Date) {
            var t = v.getTime();
            if (isNaN(t)) throw new Error('invalid Date');
            return { $date: { $numberLong: String(t) } };
        }
        if (v instanceof NumberLong) return { $numberLong: v.str };
        if (v instanceof NumberInt) return { $numberInt: String(v.value) };
        if (v instanceof NumberDecimal) return { $numberDecimal: v.str };
        if (v instanceof Timestamp) return { $timestamp: { t: v.t, i: v.i } };
        if (v instanceof BinData) {
            var st = v.type.toString(16);
            return { $binary: { base64: v.base64, subType: st.length < 2 ? '0' + st : st } };
        }
        if (v instanceof RegExp) {
            var flags = (v.flags || '').replace(/[^imsux]/g, '').split('').sort().join('');
            return { $regularExpression: { pattern: v.source, options: flags } };
        }
        if (v instanceof MinKeyType) return { $minKey: 1 };
        if (v instanceof MaxKeyType) return { $maxKey: 1 };
        if (v instanceof Code) return v.scope ? { $code: v.code, $scope: toExt(v.scope) } : { $code: v.code };
        if (v instanceof DBRef) {
            var ref = { $ref: v.$ref, $id: toExt(v.$id) };
            if (v.$db !== undefined) ref.$db = v.$db;
            return ref;
        }
        if (v instanceof Number || v instanceof String || v instanceof Boolean) return toExt(v.valueOf());
        if (Array.isArray(v)) {
            var arr = new Array(v.length);
            for (var i = 0; i < v.length; i++) arr[i] = toExt(v[i]);
            return arr;
        }
        var out = {};
        var keys = Object.keys(v);
        for (var k = 0; k < keys.length; k++) {
            var val = v[keys[k]];
            if (typeof val === 'function') continue;
            out[keys[k]] = toExt(val);
        }
        return out;
    }

    function toExtJSON(v) { return JSON.stringify(toExt(v)); }

    function revive(key, v) {
        if (v === null || typeof v !== 'object' || Array.isArray(v)) return v;
        var keys = Object.keys(v);
        if (keys.length === 0 || keys[0].charAt(0) !== '$') return v;
        switch (keys[0]) {
            case '$oid': if (keys.length === 1) return new ObjectId(v.$oid); break;
            case '$numberInt': if (keys.length === 1) return parseInt(v.$numberInt, 10); break;
            case '$numberDouble':
                if (keys.length === 1) {
                    if (v.$numberDouble === 'Infinity') return Infinity;
                    if (v.$numberDouble === '-Infinity') return -Infinity;
                    if (v.$numberDouble === 'NaN') return NaN;
                    return parseFloat(v.$numberDouble);
                }
                break;
            case '$numberLong': if (keys.length === 1) return new NumberLong(v.$numberLong); break;
            case '$numberDecimal': if (keys.length === 1) return new NumberDecimal(v.$numberDecimal); break;
            case '$date':
                if (keys.length === 1) {
                    var d = v.$date;
                    if (d instanceof NumberLong) return new Date(Number(d.str));
                    if (typeof d === 'number') return new Date(d);
                    return ISODate(d);
                }
                break;
            case '$binary':
                if (keys.length === 1 && v.$binary && typeof v.$binary === 'object')
                    return new BinData(parseInt(v.$binary.subType, 16), v.$binary.base64);
                break;
            case '$timestamp': if (keys.length === 1) return new Timestamp(v.$timestamp.t, v.$timestamp.i); break;
            case '$regularExpression':
                if (keys.length === 1) {
                    try {
                        return new RegExp(v.$regularExpression.pattern, v.$regularExpression.options.replace(/[^gimsuy]/g, ''));
                    } catch (e) { return v; }
                }
                break;
            case '$minKey': if (keys.length === 1) return MinKey; break;
            case '$maxKey': if (keys.length === 1) return MaxKey; break;
            case '$undefined': if (keys.length === 1) return undefined; break;
            case '$symbol': if (keys.length === 1) return v.$symbol; break;
            case '$code': return new Code(v.$code, v.$scope);
            case '$dbPointer': if (keys.length === 1) return new DBRef(v.$dbPointer.$ref, v.$dbPointer.$id); break;
            case '$ref': if (v.$id !== undefined) return new DBRef(v.$ref, v.$id, v.$db); break;
        }
        return v;
    }

    var RAW = Symbol('roboRaw');

    // Parses a server document and remembers its exact Extended JSON, so unmodified results keep their BSON types on display.
    function fromServer(raw) {
        var obj = JSON.parse(raw, revive);
        if (obj && typeof obj === 'object') Object.defineProperty(obj, RAW, { value: raw, enumerable: false });
        return obj;
    }

    function command(dbName, cmd) {
        return fromServer(N.command(dbName, toExtJSON(cmd)));
    }

    // ------------------------------------------------------------------ cursors

    function NativeCursorMixin(proto) {
        proto._ensure = function () {
            if (this._cursorId === undefined) {
                this._cursorId = this._open();
                this._buffer = [];
                this._position = 0;
                this._exhausted = false;
            }
        };
        proto.hasNext = function () {
            this._ensure();
            if (this._position >= this._buffer.length && !this._exhausted) {
                this._buffer = N.cursorNext(this._cursorId, 101).map(fromServer);
                this._position = 0;
                if (this._buffer.length === 0) this._exhausted = true;
            }
            return this._position < this._buffer.length;
        };
        proto.next = function () {
            if (!this.hasNext()) throw new Error('error hasNext: false');
            return this._buffer[this._position++];
        };
        proto.tryNext = function () { return this.hasNext() ? this.next() : null; };
        proto.toArray = function () {
            if (this._arr) return this._arr;
            var out = [];
            while (this.hasNext()) out.push(this.next());
            this._arr = out;
            return out;
        };
        proto.forEach = function (fn) { while (this.hasNext()) fn(this.next()); };
        proto.map = function (fn) { var out = []; while (this.hasNext()) out.push(fn(this.next())); return out; };
        proto.itcount = function () { var n = 0; while (this.hasNext()) { this.next(); n++; } return n; };
        proto.objsLeftInBatch = function () { this._ensure(); return this._buffer.length - this._position; };
        proto.isExhausted = function () { return !this.hasNext(); };
        proto.close = function () { if (this._cursorId !== undefined) N.cursorClose(this._cursorId); this._exhausted = true; this._buffer = []; this._position = 0; };
        proto.pretty = function () { return this; };
        proto.shellPrint = function () { printjson(this.toArray()); };
    }

    function DBQuery(collection, filter, projection) {
        this._collection = collection;
        this._db = collection._db;
        this._filter = filter === undefined ? {} : filter;
        this._projection = projection;
        this._sort = undefined;
        this._skip = 0;
        this._limit = 0;
        this._batchSize = 0;
        this._hint = undefined;
        this._maxTimeMS = 0;
        this._collation = undefined;
        this._comment = undefined;
    }
    DBQuery.prototype._checkModify = function () {
        if (this._cursorId !== undefined) throw new Error('query already executed');
    };
    DBQuery.prototype.sort = function (s) { this._checkModify(); this._sort = s; return this; };
    DBQuery.prototype.skip = function (n) { this._checkModify(); this._skip = Number(n); return this; };
    DBQuery.prototype.limit = function (n) { this._checkModify(); this._limit = Number(n); return this; };
    DBQuery.prototype.batchSize = function (n) { this._checkModify(); this._batchSize = Number(n); return this; };
    DBQuery.prototype.hint = function (h) { this._checkModify(); this._hint = h; return this; };
    DBQuery.prototype.maxTimeMS = function (ms) { this._checkModify(); this._maxTimeMS = Number(ms); return this; };
    DBQuery.prototype.collation = function (c) { this._checkModify(); this._collation = c; return this; };
    DBQuery.prototype.comment = function (c) { this._checkModify(); this._comment = c; return this; };
    DBQuery.prototype.projection = function (p) { this._checkModify(); this._projection = p; return this; };
    DBQuery.prototype.readPref = function () { return this; };
    DBQuery.prototype.readConcern = function () { return this; };
    DBQuery.prototype.noCursorTimeout = function () { return this; };
    DBQuery.prototype.allowDiskUse = function () { return this; };
    DBQuery.prototype.addOption = function () { return this; };
    DBQuery.prototype.snapshot = function () { return this; };
    DBQuery.prototype.min = function (m) { this._min = m; return this; };
    DBQuery.prototype.max = function (m) { this._max = m; return this; };
    DBQuery.prototype.showRecordId = function () { this._showRecordId = true; return this; };
    DBQuery.prototype.returnKey = function () { this._returnKey = true; return this; };
    DBQuery.prototype._spec = function () {
        var o = { filter: this._filter };
        if (this._projection !== undefined) o.projection = this._projection;
        if (this._sort !== undefined) o.sort = this._sort;
        if (this._skip) o.skip = this._skip;
        if (this._limit > 0) o.limit = this._limit;
        if (this._limit < 0) { o.limit = -this._limit; o.singleBatch = true; }
        if (this._batchSize) o.batchSize = this._batchSize;
        if (this._hint !== undefined) o.hint = this._hint;
        if (this._maxTimeMS) o.maxTimeMS = this._maxTimeMS;
        if (this._collation !== undefined) o.collation = this._collation;
        if (this._comment !== undefined) o.comment = this._comment;
        if (this._min !== undefined) o.min = this._min;
        if (this._max !== undefined) o.max = this._max;
        if (this._showRecordId) o.showRecordId = true;
        if (this._returnKey) o.returnKey = true;
        return o;
    };
    DBQuery.prototype._open = function () {
        return N.find(this._db._name, this._collection._name, toExtJSON(this._spec()));
    };
    NativeCursorMixin(DBQuery.prototype);
    DBQuery.prototype.count = function (applySkipLimit) {
        var cmd = { count: this._collection._name, query: this._filter };
        if (applySkipLimit) {
            if (this._skip) cmd.skip = this._skip;
            if (this._limit) cmd.limit = Math.abs(this._limit);
        }
        if (this._hint !== undefined) cmd.hint = this._hint;
        if (this._collation !== undefined) cmd.collation = this._collation;
        return toNumber(command(this._db._name, cmd).n);
    };
    DBQuery.prototype.size = function () { return this.count(true); };
    DBQuery.prototype.length = function () { return this.toArray().length; };
    DBQuery.prototype.explain = function (verbosity) {
        var find = { find: this._collection._name };
        var spec = this._spec();
        Object.assign(find, spec);
        return command(this._db._name, { explain: find, verbosity: verbosity === true ? 'allPlansExecution' : (verbosity || 'queryPlanner') });
    };
    DBQuery.prototype.toString = function () { return 'DBQuery: ' + this._db._name + '.' + this._collection._name + ' -> ' + tojson(this._filter); };

    /// `collection` is null for database-level pipelines such as $currentOp.
    function AggregateCursor(db, collection, pipeline, options) {
        this._db = db;
        this._collection = collection;
        this._pipeline = pipeline;
        this._options = options || {};
    }
    AggregateCursor.prototype._open = function () {
        if (this._collection === null) return N.aggregateDb(this._db._name, toExtJSON(this._pipeline), toExtJSON(this._options));
        return N.aggregate(this._db._name, this._collection._name, toExtJSON(this._pipeline), toExtJSON(this._options));
    };
    NativeCursorMixin(AggregateCursor.prototype);
    AggregateCursor.prototype.toString = function () { return 'AggregateCursor'; };

    // ------------------------------------------------------------------ write results

    function WriteResult(kind, n, extra, ms) {
        this._kind = kind;
        this.nInserted = 0;
        this.nUpserted = 0;
        this.nMatched = 0;
        this.nModified = 0;
        this.nRemoved = 0;
        this._ms = ms;
        if (kind === 'insert') this.nInserted = n;
        if (kind === 'remove') this.nRemoved = n;
        if (kind === 'update') {
            this.nMatched = extra.nMatched;
            this.nModified = extra.nModified;
            this.nUpserted = extra.nUpserted;
            if (extra._id !== undefined) this._id = extra._id;
        }
    }
    WriteResult.prototype.getUpsertedId = function () { return this._id === undefined ? null : { _id: this._id }; };
    WriteResult.prototype.shellPrint = function () {
        switch (this._kind) {
            case 'insert': return 'Inserted ' + this.nInserted + ' record(s) in ' + this._ms + 'ms';
            case 'remove': return 'Removed ' + this.nRemoved + ' record(s) in ' + this._ms + 'ms';
            default:
                if (this.nUpserted > 0) return 'Updated ' + this.nUpserted + ' new record(s) in ' + this._ms + 'ms';
                return 'Updated ' + this.nModified + ' existing record(s) in ' + this._ms + 'ms';
        }
    };
    WriteResult.prototype.toString = function () {
        var o = {};
        if (this._kind === 'insert') o.nInserted = this.nInserted;
        else if (this._kind === 'remove') o.nRemoved = this.nRemoved;
        else { o.nMatched = this.nMatched; o.nUpserted = this.nUpserted; o.nModified = this.nModified; if (this._id !== undefined) o._id = this._id; }
        return 'WriteResult(' + tojson(o) + ')';
    };
    WriteResult.prototype.tojson = WriteResult.prototype.toString;


    function toNumber(v) {
        if (v instanceof NumberLong || v instanceof NumberInt || v instanceof NumberDecimal) return v.valueOf();
        return v;
    }

    function hasOperators(u) {
        if (Array.isArray(u)) return true;
        var keys = Object.keys(u || {});
        return keys.length > 0 && keys[0].charAt(0) === '$';
    }

    function ensureId(doc) {
        if (doc && typeof doc === 'object' && !Array.isArray(doc) && doc._id === undefined) {
            var copy = { _id: new ObjectId() };
            for (var k in doc) if (Object.prototype.hasOwnProperty.call(doc, k)) copy[k] = doc[k];
            return copy;
        }
        return doc;
    }

    function normalizeQuery(q) {
        if (q === undefined || q === null) return {};
        if (typeof q !== 'object' || q instanceof ObjectId || q instanceof NumberLong || q instanceof BinData) return { _id: q };
        return q;
    }

    // ------------------------------------------------------------------ DBCollection

    function DBCollection(db, name) {
        this._db = db;
        this._name = name;
        this._shortName = name;
        this._fullName = db._name + '.' + name;
        return new Proxy(this, {
            get: function (target, prop, receiver) {
                if (typeof prop !== 'string' || prop in target || prop.charAt(0) === '_') return Reflect.get(target, prop, receiver);
                return target._db.getCollection(target._name + '.' + prop);
            }
        });
    }
    var C = DBCollection.prototype;
    C.getName = function () { return this._name; };
    C.getFullName = function () { return this._fullName; };
    C.getDB = function () { return this._db; };
    C.getMongo = function () { return this._db.getMongo(); };
    C.toString = function () { return this._fullName; };
    C.tojson = C.toString;
    C.shellPrint = function () { return this._fullName; };

    C.find = function (filter, projection, options) {
        var q = new DBQuery(this, normalizeQuery(filter), projection);
        if (options) {
            if (options.sort) q.sort(options.sort);
            if (options.skip) q.skip(options.skip);
            if (options.limit) q.limit(options.limit);
            if (options.projection) q.projection(options.projection);
        }
        return q;
    };
    C.findOne = function (filter, projection, options) {
        var q = new DBQuery(this, normalizeQuery(filter), projection);
        if (options && options.sort) q.sort(options.sort);
        q.limit(-1);
        return q.hasNext() ? q.next() : null;
    };
    C.count = function (query, options) {
        options = options || {};
        var cmd = { count: this._name, query: normalizeQuery(query) };
        ['limit', 'skip', 'hint', 'maxTimeMS', 'collation'].forEach(function (k) { if (options[k] !== undefined) cmd[k] = options[k]; });
        return toNumber(command(this._db._name, cmd).n);
    };
    C.countDocuments = function (query, options) {
        options = options || {};
        var pipeline = [{ $match: normalizeQuery(query) }];
        if (options.skip) pipeline.push({ $skip: options.skip });
        if (options.limit) pipeline.push({ $limit: options.limit });
        pipeline.push({ $group: { _id: 1, n: { $sum: 1 } } });
        var res = this.aggregate(pipeline).toArray();
        return res.length ? toNumber(res[0].n) : 0;
    };
    C.estimatedDocumentCount = function () { return toNumber(command(this._db._name, { count: this._name }).n); };
    C.distinct = function (key, query, options) {
        var cmd = { distinct: this._name, key: key, query: normalizeQuery(query) };
        if (options && options.collation) cmd.collation = options.collation;
        return command(this._db._name, cmd).values;
    };
    C.aggregate = function (pipeline, options) {
        if (!Array.isArray(pipeline)) {
            pipeline = Array.prototype.slice.call(arguments);
            options = {};
        }
        options = options || {};
        if (options.explain) {
            var cmd = { aggregate: this._name, pipeline: pipeline, explain: true };
            return command(this._db._name, cmd);
        }
        return new AggregateCursor(this._db, this, pipeline, options);
    };
    C.insert = function (docs, options) {
        var started = Date.now();
        var list = Array.isArray(docs) ? docs : [docs];
        list = list.map(ensureId);
        var ordered = !(options && options.ordered === false);
        var reply = (command(this._db._name, { insert: this._name, documents: list, ordered: ordered }));
        return new WriteResult('insert', toNumber(reply.n), null, Date.now() - started);
    };
    C.insertOne = function (doc) {
        var d = ensureId(doc);
        (command(this._db._name, { insert: this._name, documents: [d] }));
        return { acknowledged: true, insertedId: d._id };
    };
    C.insertMany = function (docs, options) {
        var list = docs.map(ensureId);
        var ordered = !(options && options.ordered === false);
        (command(this._db._name, { insert: this._name, documents: list, ordered: ordered }));
        return { acknowledged: true, insertedIds: list.map(function (d) { return d._id; }) };
    };
    C._update = function (q, u, upsert, multi, extra) {
        var stmt = { q: normalizeQuery(q), u: u, upsert: !!upsert, multi: !!multi };
        if (extra) ['arrayFilters', 'collation', 'hint'].forEach(function (k) { if (extra[k] !== undefined) stmt[k] = extra[k]; });
        var reply = (command(this._db._name, { update: this._name, updates: [stmt] }));
        var upserted = reply.upserted && reply.upserted.length ? reply.upserted[0]._id : undefined;
        var n = toNumber(reply.n);
        return {
            nMatched: upserted !== undefined ? 0 : n,
            nModified: toNumber(reply.nModified) || 0,
            nUpserted: upserted !== undefined ? 1 : 0,
            _id: upserted
        };
    };
    C.update = function (query, update, upsert, multi) {
        var started = Date.now();
        var options = {};
        if (upsert !== null && typeof upsert === 'object') {
            options = upsert;
            upsert = options.upsert;
            multi = options.multi;
        }
        if (multi && !hasOperators(update)) throw new Error('multi update only works with $ operators');
        var res = this._update(query, update, upsert, multi, options);
        return new WriteResult('update', 0, res, Date.now() - started);
    };
    C._crudUpdate = function (q, u, options, multi) {
        options = options || {};
        var res = this._update(q, u, options.upsert, multi, options);
        var out = { acknowledged: true, matchedCount: res.nMatched, modifiedCount: res.nModified };
        if (res._id !== undefined) out.upsertedId = res._id;
        return out;
    };
    C.updateOne = function (q, u, options) {
        if (!hasOperators(u)) throw new Error('the update operation document must contain atomic operators.');
        return this._crudUpdate(q, u, options, false);
    };
    C.updateMany = function (q, u, options) {
        if (!hasOperators(u)) throw new Error('the update operation document must contain atomic operators.');
        return this._crudUpdate(q, u, options, true);
    };
    C.replaceOne = function (q, doc, options) {
        if (hasOperators(doc)) throw new Error('the replace operation document must not contain atomic operators');
        return this._crudUpdate(q, doc, options, false);
    };
    C.save = function (doc) {
        if (doc._id === undefined) return this.insert(doc);
        return this.update({ _id: doc._id }, doc, { upsert: true });
    };
    C._delete = function (q, limit, extra) {
        var stmt = { q: normalizeQuery(q), limit: limit };
        if (extra && extra.collation) stmt.collation = extra.collation;
        if (extra && extra.hint) stmt.hint = extra.hint;
        return toNumber((command(this._db._name, { delete: this._name, deletes: [stmt] })).n);
    };
    C.remove = function (query, justOne) {
        var started = Date.now();
        var options = {};
        if (justOne !== null && typeof justOne === 'object') { options = justOne; justOne = options.justOne; }
        if (query === undefined) throw new Error('remove needs a query');
        var n = this._delete(query, justOne ? 1 : 0, options);
        return new WriteResult('remove', n, null, Date.now() - started);
    };
    C.deleteOne = function (q, options) { return { acknowledged: true, deletedCount: this._delete(q, 1, options) }; };
    C.deleteMany = function (q, options) { return { acknowledged: true, deletedCount: this._delete(q, 0, options) }; };
    C.findAndModify = function (args) {
        var cmd = Object.assign({ findAndModify: this._name }, args);
        if (cmd.query !== undefined) cmd.query = normalizeQuery(cmd.query);
        return command(this._db._name, cmd).value;
    };
    C.findOneAndUpdate = function (filter, update, options) {
        options = options || {};
        return this.findAndModify({
            query: filter, update: update, fields: options.projection, sort: options.sort,
            upsert: !!options.upsert, new: !!options.returnNewDocument, arrayFilters: options.arrayFilters
        });
    };
    C.findOneAndReplace = function (filter, replacement, options) {
        if (hasOperators(replacement)) throw new Error('the replace operation document must not contain atomic operators');
        options = options || {};
        return this.findAndModify({
            query: filter, update: replacement, fields: options.projection, sort: options.sort,
            upsert: !!options.upsert, new: !!options.returnNewDocument
        });
    };
    C.findOneAndDelete = function (filter, options) {
        options = options || {};
        return this.findAndModify({ query: filter, remove: true, fields: options.projection, sort: options.sort });
    };
    C.bulkWrite = function (ops, options) {
        var self = this;
        var result = { acknowledged: true, insertedCount: 0, matchedCount: 0, modifiedCount: 0, deletedCount: 0, upsertedCount: 0, insertedIds: {}, upsertedIds: {} };
        ops.forEach(function (op, index) {
            var kind = Object.keys(op)[0];
            var a = op[kind];
            switch (kind) {
                case 'insertOne': var r = self.insertOne(a.document); result.insertedCount++; result.insertedIds[index] = r.insertedId; break;
                case 'updateOne': case 'updateMany': case 'replaceOne':
                    var u = self._update(a.filter, a.update || a.replacement, a.upsert, kind === 'updateMany', a);
                    result.matchedCount += u.nMatched; result.modifiedCount += u.nModified;
                    if (u._id !== undefined) { result.upsertedCount++; result.upsertedIds[index] = u._id; }
                    break;
                case 'deleteOne': result.deletedCount += self._delete(a.filter, 1, a); break;
                case 'deleteMany': result.deletedCount += self._delete(a.filter, 0, a); break;
                default: throw new Error('unknown bulkWrite operation: ' + kind);
            }
        });
        return result;
    };
    C.drop = function () {
        try {
            command(this._db._name, { drop: this._name });
            return true;
        } catch (e) {
            if (e.code === 26) return false;
            throw e;
        }
    };
    C.renameCollection = function (newName, dropTarget) {
        return command('admin', { renameCollection: this._fullName, to: this._db._name + '.' + newName, dropTarget: !!dropTarget });
    };
    C.getIndexes = function () { return N.listIndexes(this._db._name, this._name).map(fromServer); };
    C.getIndices = C.getIndexes;
    C.getIndexSpecs = C.getIndexes;
    C.getIndexKeys = function () { return this.getIndexes().map(function (i) { return i.key; }); };
    function indexSpec(keys, options) {
        var name = Object.keys(keys).map(function (k) { return k + '_' + keys[k]; }).join('_');
        return Object.assign({ key: keys, name: name }, options);
    }
    C.createIndex = function (keys, options) {
        return command(this._db._name, { createIndexes: this._name, indexes: [indexSpec(keys, options)] });
    };
    C.ensureIndex = C.createIndex;
    C.createIndexes = function (list, options) {
        return command(this._db._name, { createIndexes: this._name, indexes: list.map(function (keys) { return indexSpec(keys, options); }) });
    };
    C.dropIndex = function (index) { return command(this._db._name, { dropIndexes: this._name, index: index }); };
    C.dropIndexes = function (index) { return command(this._db._name, { dropIndexes: this._name, index: index === undefined ? '*' : index }); };
    C.reIndex = function () { return command(this._db._name, { reIndex: this._name }); };
    C.stats = function (scale) {
        var opts = typeof scale === 'object' ? scale : { scale: scale };
        try {
            var cmd = { collStats: this._name };
            if (opts && opts.scale) cmd.scale = opts.scale;
            return command(this._db._name, cmd);
        } catch (e) {
            var storage = { storageStats: {} };
            if (opts && opts.scale) storage.storageStats.scale = opts.scale;
            var res = this.aggregate([{ $collStats: storage }]).toArray();
            return res.length ? res[0] : {};
        }
    };
    C.dataSize = function () { return this.stats().size; };
    C.storageSize = function () { return this.stats().storageSize; };
    C.totalIndexSize = function () { return this.stats().totalIndexSize; };
    C.totalSize = function () { var s = this.stats(); return toNumber(s.storageSize) + toNumber(s.totalIndexSize); };
    C.validate = function (full) { return command(this._db._name, { validate: this._name, full: !!full }); };
    C.exists = function () {
        var infos = this._db.getCollectionInfos({ name: this._name });
        return infos.length ? infos[0] : null;
    };
    C.isCapped = function () { var s = this.stats(); return !!s.capped; };
    C.runCommand = function (cmd, extra) {
        var o = {};
        o[cmd] = this._name;
        return this._db.runCommand(Object.assign(o, extra));
    };
    C.getShardVersion = function () { return this._db.adminCommand({ getShardVersion: this._fullName }); };
    C.getShardDistribution = function () { return this._db.getSiblingDB('config').getCollection('chunks').find({ ns: this._fullName }); };
    C.watch = function () { throw new Error('Change streams are not supported in this shell'); };
    C.latencyStats = function () { return this.aggregate([{ $collStats: { latencyStats: {} } }]); };

    // ------------------------------------------------------------------ DB

    function DB(name) {
        this._name = name;
        this._collections = {};
        return new Proxy(this, {
            get: function (target, prop, receiver) {
                if (typeof prop !== 'string' || prop in target || prop.charAt(0) === '_') return Reflect.get(target, prop, receiver);
                return target.getCollection(prop);
            }
        });
    }
    var D = DB.prototype;
    D.getName = function () { return this._name; };
    D.toString = function () { return this._name; };
    D.tojson = D.toString;
    D.shellPrint = function () { return this._name; };
    D.getSiblingDB = function (name) { return new DB(String(name)); };
    D.getDB = D.getSiblingDB;
    D.getCollection = function (name) {
        name = String(name);
        if (!this._collections[name]) this._collections[name] = new DBCollection(this, name);
        return this._collections[name];
    };
    D.getMongo = function () { return mongo; };
    D.runCommand = function (cmd, extra) {
        if (typeof cmd === 'string') {
            var o = {};
            o[cmd] = 1;
            cmd = o;
        }
        return command(this._name, Object.assign(cmd, extra));
    };
    D.adminCommand = function (cmd) { return new DB('admin').runCommand(cmd); };
    D.getCollectionInfos = function (filter, options) {
        var cmd = { listCollections: 1, filter: filter || {} };
        if (options && options.nameOnly) cmd.nameOnly = true;
        cmd.authorizedCollections = true;
        var reply = command(this._name, cmd);
        return reply.cursor.firstBatch;
    };
    D.getCollectionNames = function () {
        return this.getCollectionInfos({}, { nameOnly: true }).map(function (c) { return c.name; }).sort();
    };
    D.stats = function (scale) { var c = { dbStats: 1 }; if (scale) c.scale = scale; return this.runCommand(c); };
    D.serverStatus = function (opts) { return this.runCommand(Object.assign({ serverStatus: 1 }, opts)); };
    D.hostInfo = function () { return this.adminCommand({ hostInfo: 1 }); };
    D.serverBuildInfo = function () { return this.adminCommand({ buildInfo: 1 }); };
    D.version = function () { return this.serverBuildInfo().version; };
    D.serverCmdLineOpts = function () { return this.adminCommand({ getCmdLineOpts: 1 }); };
    D.isMaster = function () { return this.runCommand({ isMaster: 1 }); };
    D.hello = function () { return this.runCommand({ hello: 1 }); };
    D.currentOp = function (arg) {
        var filter = {};
        var all = false;
        if (arg === true) all = true;
        else if (arg && typeof arg === 'object') { for (var k in arg) { if (k === '$all') all = !!arg[k]; else if (k === '$ownOps') {} else filter[k] = arg[k]; } }
        var pipeline = [{ $currentOp: { allUsers: true, idleConnections: all } }];
        if (Object.keys(filter).length) pipeline.push({ $match: filter });
        return { inprog: new DB('admin').aggregate(pipeline).toArray(), ok: 1 };
    };
    D.killOp = function (op) {
        if (op === undefined) throw new Error('no opNum to kill specified');
        return this.adminCommand({ killOp: 1, op: op });
    };
    D.getUsers = function (args) { return this.runCommand(Object.assign({ usersInfo: 1 }, args)).users; };
    D.getUser = function (name, args) {
        var users = this.runCommand(Object.assign({ usersInfo: { user: name, db: this._name } }, args)).users;
        return users.length ? users[0] : null;
    };
    D.createUser = function (user, wc) {
        var c = { createUser: user.user };
        for (var k in user) if (k !== 'user') c[k] = user[k];
        if (wc) c.writeConcern = wc;
        return this.runCommand(c);
    };
    D.dropUser = function (name) { return this.runCommand({ dropUser: name }); };
    D.updateUser = function (name, update) { return this.runCommand(Object.assign({ updateUser: name }, update)); };
    D.grantRolesToUser = function (name, roles) { return this.runCommand({ grantRolesToUser: name, roles: roles }); };
    D.revokeRolesFromUser = function (name, roles) { return this.runCommand({ revokeRolesFromUser: name, roles: roles }); };
    D.getRoles = function (args) { return this.runCommand(Object.assign({ rolesInfo: 1 }, args)).roles; };
    D.dropDatabase = function () { return this.runCommand({ dropDatabase: 1 }); };
    D.createCollection = function (name, options) {
        return this.runCommand(Object.assign({ create: name }, options));
    };
    D.createView = function (name, source, pipeline, options) {
        return this.runCommand(Object.assign({ create: name, viewOn: source, pipeline: pipeline }, options));
    };
    D.printCollectionStats = function (scale) {
        var self = this;
        this.getCollectionNames().forEach(function (name) {
            print(name);
            printjson(self.getCollection(name).stats(scale));
            print('---');
        });
    };
    D.getProfilingStatus = function () { var r = this.runCommand({ profile: -1 }); delete r.ok; return r; };
    D.setProfilingLevel = function (level, slowms) { var c = { profile: level }; if (slowms !== undefined) c.slowms = slowms; return this.runCommand(c); };
    D.getProfilingLevel = function () { return this.runCommand({ profile: -1 }).was; };
    D.getLogComponents = function () { return this.adminCommand({ getParameter: 1, logComponentVerbosity: 1 }).logComponentVerbosity; };
    D.repairDatabase = function () { throw new Error('repairDatabase was removed in MongoDB 4.2'); };
    D.eval = function () { throw new Error('db.eval was removed in MongoDB 4.2'); };
    D.fsyncLock = function () { return this.adminCommand({ fsync: 1, lock: true }); };
    D.fsyncUnlock = function () { return this.adminCommand({ fsyncUnlock: 1 }); };
    D.getReplicationInfo = function () { return this.adminCommand({ replSetGetStatus: 1 }); };
    D.printReplicationInfo = function () { printjson(this.getReplicationInfo()); };
    D.getLastError = function () { return null; };
    D.getLastErrorObj = function () { return { ok: 1 }; };
    D.watch = function () { throw new Error('Change streams are not supported in this shell'); };
    D.aggregate = function (pipeline, options) {
        return new AggregateCursor(this, null, pipeline, options);
    };

    var mongo = {
        host: N.host(),
        getDB: function (name) { return new DB(name); },
        getDBNames: function () { return command('admin', { listDatabases: 1, nameOnly: true }).databases.map(function (d) { return d.name; }); },
        getDBs: function () { return command('admin', { listDatabases: 1 }); },
        setSlaveOk: function () {},
        setSecondaryOk: function () {},
        toString: function () { return 'connection to ' + this.host; }
    };
    function Mongo() { return mongo; }

    var rs = {
        status: function () { return mongo.getDB('admin').runCommand({ replSetGetStatus: 1 }); },
        conf: function () { return mongo.getDB('admin').runCommand({ replSetGetConfig: 1 }).config; },
        config: function () { return rs.conf(); },
        isMaster: function () { return mongo.getDB('admin').runCommand({ isMaster: 1 }); },
        hello: function () { return mongo.getDB('admin').runCommand({ hello: 1 }); },
        printReplicationInfo: function () { printjson(rs.status()); },
        printSecondaryReplicationInfo: function () { printjson(rs.status()); },
        slaveOk: function () {},
        secondaryOk: function () {},
        stepDown: function (secs) { return mongo.getDB('admin').runCommand({ replSetStepDown: secs || 60 }); },
        help: function () { print('rs.status(), rs.conf(), rs.isMaster(), rs.stepDown()'); }
    };
    var sh = {
        status: function () { return mongo.getDB('admin').runCommand({ listShards: 1 }); },
        help: function () { print('sh.status()'); }
    };

    // ------------------------------------------------------------------ printing

    function tojson(x, indent, nolint) {
        if (indent === undefined) indent = '';
        if (x === null) return 'null';
        if (x === undefined) return 'undefined';
        switch (typeof x) {
            case 'string': return JSON.stringify(x);
            case 'number': return String(x);
            case 'boolean': return String(x);
            case 'function': return x.toString();
        }
        if (x instanceof Date) {
            return isNaN(x.getTime()) ? 'ISODate("Invalid Date")' : 'ISODate("' + x.toISOString() + '")';
        }
        if (x instanceof RegExp) return x.toString();
        if (typeof x.tojson === 'function' && !isPlainObject(x) && !Array.isArray(x)) return x.tojson(indent, nolint);
        var nl = nolint ? ' ' : '\n';
        var inner = nolint ? '' : indent + '\t';
        if (Array.isArray(x)) {
            if (x.length === 0) return '[ ]';
            var parts = x.map(function (v) { return tojson(v, inner, nolint); });
            return '[' + nl + inner + parts.join(',' + nl + inner) + nl + (nolint ? '' : indent) + ']';
        }
        var keys = Object.keys(x).filter(function (k) { return typeof x[k] !== 'function'; });
        if (keys.length === 0) return '{ }';
        var lines = keys.map(function (k) { return JSON.stringify(k) + ' : ' + tojson(x[k], inner, nolint); });
        return '{' + nl + inner + lines.join(',' + nl + inner) + nl + (nolint ? '' : indent) + '}';
    }
    function tojsononeline(x) { return tojson(x, '', true); }

    function print() {
        var parts = [];
        for (var i = 0; i < arguments.length; i++) {
            var a = arguments[i];
            parts.push(typeof a === 'string' ? a : tojson(a));
        }
        N.print(parts.join(' '));
    }
    function printjson(x) { N.print(tojson(x)); }
    function printjsononeline(x) { N.print(tojsononeline(x)); }

    function formatSize(bytes) {
        var gb = toNumber(bytes || 0) / (1024 * 1024 * 1024);
        return gb.toFixed(3) + 'GB';
    }

    function shellHelper(cmd, arg) {
        cmd = String(cmd).toLowerCase();
        if (cmd === 'use') {
            global.db = new DB(String(arg));
            print('switched to db ' + arg);
            return;
        }
        if (cmd === 'show') {
            var what = String(arg).toLowerCase();
            if (what === 'dbs' || what === 'databases') {
                var dbs = command('admin', { listDatabases: 1 }).databases;
                var width = Math.max.apply(null, dbs.map(function (d) { return d.name.length; }).concat([4]));
                dbs.forEach(function (d) {
                    var pad = new Array(width - d.name.length + 3).join(' ');
                    print(d.name + pad + formatSize(d.sizeOnDisk));
                });
                return;
            }
            if (what === 'collections' || what === 'tables') { global.db.getCollectionNames().forEach(function (n) { print(n); }); return; }
            if (what === 'users') { global.db.getUsers().forEach(function (u) { printjson(u); }); return; }
            if (what === 'roles') { global.db.getRoles().forEach(function (r) { printjson(r); }); return; }
            if (what === 'profile') { return global.db.getCollection('system.profile').find().sort({ $natural: -1 }).limit(5); }
            if (what === 'log' || what === 'logs') {
                var log = command('admin', { getLog: what === 'logs' ? '*' : 'global' });
                (log.log || log.names || []).forEach(function (l) { print(l); });
                return;
            }
            throw new Error("don't know how to show [" + arg + ']');
        }
        if (cmd === 'set') return;
        throw new Error('unknown shell helper: ' + cmd);
    }
    shellHelper.use = function (name) { return shellHelper('use', name); };
    shellHelper.show = function (what) { return shellHelper('show', what); };

    function sleep(ms) { N.sleep(Number(ms)); }
    function hex_md5(s) { return N.md5(String(s)); }
    function load(path) { return (0, eval)(N.readFile(String(path))); }
    function cat(path) { return N.readFile(String(path)); }
    function version() { return '4.4.0-robo-tribute'; }
    function quit() {}
    function getMemInfo() { return {}; }
    function isNumber(x) { return typeof x === 'number'; }
    function isString(x) { return typeof x === 'string'; }
    function isObject(x) { return typeof x === 'object' && x !== null; }

    // ------------------------------------------------------------------ Robo integration

    function __roboSplit(source) {
        try {
            var ast = esprima.parseScript(source, { range: true, tolerant: false });
            return JSON.stringify({ statements: ast.body.map(function (n) { return source.substring(n.range[0], n.range[1]); }) });
        } catch (e) {
            return JSON.stringify({ error: (e.description || e.message) + (e.lineNumber ? ' (line ' + e.lineNumber + ', column ' + e.column + ')' : '') });
        }
    }

    /// Extended JSON for display: the server's original text when the script did not modify the document.
    function describeDocument(v) {
        var current = toExtJSON(v);
        var raw = v && typeof v === 'object' ? v[RAW] : undefined;
        if (raw !== undefined && toExtJSON(fromServer(raw)) === current) return raw;
        return current;
    }

    function __roboDescribe(value) {
        if (value instanceof DBQuery && value._cursorId === undefined) {
            return JSON.stringify({
                kind: 'query', db: value._db._name, collection: value._collection._name, spec: toExt(value._spec())
            });
        }
        if (value instanceof AggregateCursor && value._cursorId === undefined && value._collection !== null) {
            return JSON.stringify({
                kind: 'aggregate', db: value._db._name, collection: value._collection._name,
                pipeline: toExt(value._pipeline), options: toExt(value._options)
            });
        }
        if (value instanceof DBQuery || value instanceof AggregateCursor) {
            return '{"kind":"documents","docs":[' + value.toArray().map(describeDocument).join(',') + ']}';
        }
        if (value === undefined) return JSON.stringify({ kind: 'none' });
        if (value !== null && typeof value === 'object' && typeof value.shellPrint === 'function'
            && !(value instanceof DB) && !(value instanceof DBCollection)) {
            var printed = value.shellPrint();
            return JSON.stringify({ kind: 'text', text: printed === undefined ? '' : String(printed) });
        }
        if (value instanceof DB || value instanceof DBCollection) return JSON.stringify({ kind: 'text', text: value.toString() });
        if (value === null || typeof value !== 'object' || value instanceof Date || value instanceof ObjectId
            || value instanceof NumberLong || value instanceof NumberInt || value instanceof NumberDecimal
            || value instanceof Timestamp || value instanceof BinData || value instanceof RegExp) {
            return JSON.stringify({ kind: 'text', text: typeof value === 'string' ? value : tojson(value) });
        }
        if (Array.isArray(value)) {
            return '{"kind":"array","value":[' + value.map(function (v) { return (v && typeof v === 'object') ? describeDocument(v) : toExtJSON(v); }).join(',') + ']}';
        }
        return '{"kind":"documents","docs":[' + describeDocument(value) + ']}';
    }

    function __roboDbName() { return global.db && typeof global.db.getName === 'function' ? global.db.getName() : '[invalid database]'; }

    var exportsList = {
        ObjectId: ObjectId, ISODate: ISODate, NumberLong: NumberLong, NumberInt: NumberInt, NumberDecimal: NumberDecimal,
        Timestamp: Timestamp, BinData: BinData, HexData: HexData, UUID: UUID, MD5: MD5,
        LUUID: legacyUUID(0), JUUID: legacyUUID(1), NUUID: legacyUUID(2), CSUUID: legacyUUID(2), PYUUID: legacyUUID(3),
        MinKey: MinKey, MaxKey: MaxKey, DBRef: DBRef, DBPointer: DBPointer, Code: Code,
        DB: DB, DBCollection: DBCollection, DBQuery: DBQuery, DBCommandCursor: AggregateCursor, AggregateCursor: AggregateCursor,
        WriteResult: WriteResult, Mongo: Mongo, rs: rs, sh: sh,
        tojson: tojson, tojsononeline: tojsononeline, print: print, printjson: printjson, printjsononeline: printjsononeline,
        shellHelper: shellHelper, sleep: sleep, hex_md5: hex_md5, load: load, cat: cat, version: version, quit: quit, exit: quit,
        getMemInfo: getMemInfo, isNumber: isNumber, isString: isString, isObject: isObject,
        __roboSplit: __roboSplit, __roboDescribe: __roboDescribe, __roboDbName: __roboDbName
    };
    for (var name in exportsList) global[name] = exportsList[name];
    global.db = new DB(N.initialDb());
})(this);
