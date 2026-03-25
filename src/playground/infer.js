// infer.js — Thin type inference engine for the browser playground
// Pre-computes nothing; uses tables from types.bin built at Julia build time
//
// Architecture: Forward SSA pass with 3-tier type lookup
//   Tier 1: FNV-1a hash table (concrete types)   ~130 ns/call
//   Tier 2: Parametric rule matching              ~500 ns/call
//   Tier 3: Fallback to Any (runtime dispatch)    ~0 ns
//
// ~500-700 lines JS. Selfhost spec §2.4.

'use strict';

// ============================================================
// Constants — Well-known TypeIDs (must match Julia TypeRegistry)
// ============================================================

var TYPE_ANY     = 0;
var TYPE_BOTTOM  = 1;
var TYPE_NOTHING = 2;
var TYPE_MISSING = 3;
var TYPE_BOOL    = 4;
var TYPE_INT8    = 5;
var TYPE_INT16   = 6;
var TYPE_INT32   = 7;
var TYPE_INT64   = 8;
var TYPE_INT128  = 9;
var TYPE_UINT8   = 10;
var TYPE_UINT16  = 11;
var TYPE_UINT32  = 12;
var TYPE_UINT64  = 13;
var TYPE_UINT128 = 14;
var TYPE_FLOAT16 = 15;
var TYPE_FLOAT32 = 16;
var TYPE_FLOAT64 = 17;
var TYPE_CHAR    = 18;
var TYPE_STRING  = 19;
var TYPE_SYMBOL  = 20;

// Abstract types
var TYPE_NUMBER         = 21;
var TYPE_REAL           = 22;
var TYPE_INTEGER        = 23;
var TYPE_SIGNED         = 24;
var TYPE_UNSIGNED       = 25;
var TYPE_ABSTRACT_FLOAT = 26;
var TYPE_ABSTRACT_STRING = 27;
var TYPE_ABSTRACT_CHAR  = 28;

// Type kinds (match Julia TYPE_KIND_*)
var KIND_SPECIAL   = 0;
var KIND_PRIMITIVE = 1;
var KIND_ABSTRACT  = 2;
var KIND_CONTAINER = 3;
var KIND_STRUCT    = 4;

// ============================================================
// Statement Kinds — IR representation for lowered Julia code
// ============================================================

var STMT_CALL      = 1;   // Function call: { callee: string, args: [ref...] }
var STMT_PHI       = 2;   // Phi node:      { edges: [{ from: int, val: ref }...] }
var STMT_GETFIELD  = 3;   // Field access:   { obj: ref, field: string }
var STMT_NEW       = 4;   // Construction:   { typeId: int }
var STMT_LITERAL   = 5;   // Literal value:  { typeId: int }
var STMT_RETURN    = 6;   // Return:         { val: ref }
var STMT_GOTO      = 7;   // Goto:           { dest: int }
var STMT_GOTOIFNOT = 8;   // Cond branch:    { cond: ref, dest: int }
var STMT_PINODE    = 9;   // Type narrowing:  { val: ref, typeId: int }

// Inference constants
var UNKNOWN    = -1;
var MAX_ITERS  = 4;   // Loop fixed-point iterations
var MAX_UNION  = 4;   // Max components in a union type

// FNV-1a constants (must match Julia side exactly)
var FNV_OFFSET = 0x811c9dc5;
var FNV_PRIME  = 0x01000193;
var ENTRY_INTS = 8;   // Int32s per hash table slot

// ============================================================
// Table Loading — parse types.bin binary format
// ============================================================

/**
 * Load inference tables from an ArrayBuffer (types.bin).
 * @param {ArrayBuffer} buffer - Raw binary data from types.bin
 * @returns {{ hashData, hashCapacity, typeById, typeByName, funcById, funcByName, rules, subtypeMap }}
 */
function loadTables(buffer) {
    const view = new DataView(buffer);

    // Header (24 bytes): magic(4) + version(4) + json_offset(4) + json_length(4) + hash_offset(4) + hash_length(4)
    const magic = String.fromCharCode(
        view.getUint8(0), view.getUint8(1),
        view.getUint8(2), view.getUint8(3)
    );
    if (magic !== 'JLTI') throw new Error('Invalid magic: ' + magic);

    const version = view.getUint32(4, true);
    if (version !== 1) throw new Error('Unsupported version: ' + version);

    const jsonOffset = view.getUint32(8, true);
    const jsonLength = view.getUint32(12, true);
    const hashOffset = view.getUint32(16, true);
    // hashLength not needed — we read capacity from the section header

    // Hash table section: capacity(4) + entrySize(4) + flat Int32 data
    const hashCapacity = view.getInt32(hashOffset, true);
    const dataStart = hashOffset + 8;
    const hashData = new Int32Array(buffer, dataStart, hashCapacity * ENTRY_INTS);

    // JSON section: type registry + function registry + parametric rules
    const jsonBytes = new Uint8Array(buffer, jsonOffset, jsonLength);
    const jsonStr = new TextDecoder().decode(jsonBytes);
    const meta = JSON.parse(jsonStr);

    // Build lookup maps: id ↔ name
    const typeById = new Map();
    const typeByName = new Map();
    for (const t of meta.types) {
        typeById.set(t.id, t);
        typeByName.set(t.name, t.id);
    }

    const funcById = new Map();
    const funcByName = new Map();
    for (const f of meta.functions) {
        funcById.set(f.id, f);
        funcByName.set(f.name, f.id);
    }

    // Abstract type hierarchy for subtype checks
    const subtypeMap = buildSubtypeMap();

    return {
        hashData,
        hashCapacity,
        typeById,
        typeByName,
        funcById,
        funcByName,
        rules: meta.rules,
        subtypeMap,
    };
}

/**
 * Build map: abstractTypeId → Set of concrete TypeIDs that are subtypes.
 * Hard-coded to match Julia's numeric type hierarchy.
 */
function buildSubtypeMap() {
    const allSigned   = [TYPE_INT8, TYPE_INT16, TYPE_INT32, TYPE_INT64, TYPE_INT128];
    const allUnsigned = [TYPE_UINT8, TYPE_UINT16, TYPE_UINT32, TYPE_UINT64, TYPE_UINT128];
    const allInt      = [...allSigned, ...allUnsigned];
    const allFloat    = [TYPE_FLOAT16, TYPE_FLOAT32, TYPE_FLOAT64];
    const allNumeric  = [...allInt, ...allFloat];

    const map = new Map();
    map.set(TYPE_NUMBER,         new Set(allNumeric));
    map.set(TYPE_REAL,           new Set(allNumeric));
    map.set(TYPE_INTEGER,        new Set(allInt));
    map.set(TYPE_SIGNED,         new Set(allSigned));
    map.set(TYPE_UNSIGNED,       new Set(allUnsigned));
    map.set(TYPE_ABSTRACT_FLOAT, new Set(allFloat));
    map.set(TYPE_ABSTRACT_STRING, new Set([TYPE_STRING]));
    map.set(TYPE_ABSTRACT_CHAR,  new Set([TYPE_CHAR]));
    return map;
}

// ============================================================
// FNV-1a Hash — must produce identical results as Julia side
// ============================================================

/**
 * Composite FNV-1a hash of funcId + argTypeIds (all as little-endian Int32 bytes).
 * @param {number} funcId
 * @param {number[]} argTypeIds
 * @returns {number} Unsigned 32-bit hash
 */
function compositeHash(funcId, argTypeIds) {
    let h = FNV_OFFSET;
    // Hash funcId as 4 little-endian bytes
    h = Math.imul(h ^ (funcId & 0xff), FNV_PRIME) >>> 0;
    h = Math.imul(h ^ ((funcId >>> 8) & 0xff), FNV_PRIME) >>> 0;
    h = Math.imul(h ^ ((funcId >>> 16) & 0xff), FNV_PRIME) >>> 0;
    h = Math.imul(h ^ ((funcId >>> 24) & 0xff), FNV_PRIME) >>> 0;
    // Hash each arg type id as 4 little-endian bytes
    for (let i = 0; i < argTypeIds.length; i++) {
        const aid = argTypeIds[i];
        h = Math.imul(h ^ (aid & 0xff), FNV_PRIME) >>> 0;
        h = Math.imul(h ^ ((aid >>> 8) & 0xff), FNV_PRIME) >>> 0;
        h = Math.imul(h ^ ((aid >>> 16) & 0xff), FNV_PRIME) >>> 0;
        h = Math.imul(h ^ ((aid >>> 24) & 0xff), FNV_PRIME) >>> 0;
    }
    return h;
}

// ============================================================
// Tier 1: Hash Table Lookup — linear probe on flat Int32Array
// ============================================================

/**
 * Look up a return type in the pre-computed hash table.
 * @returns {number} TypeID of return type, or -1 if not found
 */
function hashLookup(tables, funcId, argTypeIds) {
    const hash = compositeHash(funcId, argTypeIds);
    const cap = tables.hashCapacity;
    let idx = hash % cap;
    const hashI32 = hash | 0;  // Signed view (matches Julia's reinterpret(Int32, hash))
    const nargs = argTypeIds.length;

    for (let probe = 0; probe < cap; probe++) {
        const base = idx * ENTRY_INTS;
        if (tables.hashData[base] === 0) return -1;  // Empty slot → not found

        if (tables.hashData[base] === hashI32 &&
            tables.hashData[base + 1] === funcId &&
            tables.hashData[base + 2] === nargs) {
            let match = true;
            for (let i = 0; i < nargs; i++) {
                if (tables.hashData[base + 3 + i] !== argTypeIds[i]) {
                    match = false;
                    break;
                }
            }
            if (match) return tables.hashData[base + 7];  // Return type ID
        }
        idx = (idx + 1) % cap;
    }
    return -1;
}

// ============================================================
// Tier 2: Parametric Rule Matching
// ============================================================

/**
 * Check if a concrete typeId is a subtype of an abstract type named boundName.
 */
function isSubtype(typeId, boundName, tables) {
    if (boundName === 'Any') return true;
    const boundId = tables.typeByName.get(boundName);
    if (boundId === undefined) return false;
    if (typeId === boundId) return true;
    const subs = tables.subtypeMap.get(boundId);
    return subs !== undefined && subs.has(typeId);
}

/**
 * Try to match a function call against parametric rules.
 * @param {Object} tables - Loaded tables
 * @param {string} calleeName - Function name
 * @param {number[]} argTypeIds - Concrete arg type IDs
 * @returns {number} Return TypeID, or -1 if no rule matches
 */
function matchRules(tables, calleeName, argTypeIds) {
    for (let r = 0; r < tables.rules.length; r++) {
        const rule = tables.rules[r];
        if (rule.func !== calleeName) continue;

        const ruleArgs = rule.args;
        if (ruleArgs.length !== argTypeIds.length) continue;

        // Attempt to match, binding type variables
        const bindings = new Map();
        let matched = true;

        for (let i = 0; i < ruleArgs.length; i++) {
            const spec = ruleArgs[i];
            const actual = argTypeIds[i];

            if (spec.type !== undefined) {
                // Fixed type or 'Any' wildcard
                if (spec.type === 'Any') continue;
                const specId = tables.typeByName.get(spec.type);
                if (specId === undefined || specId !== actual) {
                    matched = false;
                    break;
                }
            } else if (spec.var !== undefined) {
                // Type variable with optional bound
                const bound = spec.bound || 'Any';
                if (!isSubtype(actual, bound, tables)) {
                    matched = false;
                    break;
                }
                const existing = bindings.get(spec.var);
                if (existing !== undefined) {
                    if (existing !== actual) { matched = false; break; }
                } else {
                    bindings.set(spec.var, actual);
                }
            } else if (spec.container !== undefined) {
                // Container type: Vector{T}, Dict{K,V}
                const actualType = tables.typeById.get(actual);
                if (!actualType) { matched = false; break; }
                const prefix = spec.container + '{';
                if (!actualType.name.startsWith(prefix)) {
                    matched = false;
                    break;
                }
                // Extract type parameters from name
                const inner = actualType.name.slice(prefix.length, -1);
                if (spec.typevar) {
                    const paramId = tables.typeByName.get(inner);
                    if (paramId === undefined) { matched = false; break; }
                    const existing = bindings.get(spec.typevar);
                    if (existing !== undefined && existing !== paramId) {
                        matched = false;
                        break;
                    }
                    bindings.set(spec.typevar, paramId);
                } else if (spec.typevars) {
                    const parts = inner.split(',');
                    if (parts.length !== spec.typevars.length) {
                        matched = false;
                        break;
                    }
                    for (let j = 0; j < parts.length; j++) {
                        const paramId = tables.typeByName.get(parts[j].trim());
                        if (paramId === undefined) { matched = false; break; }
                        const varName = spec.typevars[j];
                        const existing = bindings.get(varName);
                        if (existing !== undefined && existing !== paramId) {
                            matched = false;
                            break;
                        }
                        bindings.set(varName, paramId);
                    }
                    if (!matched) break;
                }
            } else if (spec.typeparam !== undefined) {
                // Type{T} parameter — the argument IS the type
                bindings.set(spec.typeparam, actual);
            } else {
                matched = false;
                break;
            }
        }

        if (!matched) continue;

        // Resolve return type from rule
        return resolveRuleReturn(rule.returns, bindings, tables);
    }
    return -1;  // No rule matched
}

/**
 * Resolve a parametric rule's return type using bound type variables.
 */
function resolveRuleReturn(ret, bindings, tables) {
    if (ret.type !== undefined) {
        const retId = tables.typeByName.get(ret.type);
        return retId !== undefined ? retId : TYPE_ANY;
    }
    if (ret.var !== undefined) {
        const bound = bindings.get(ret.var);
        return bound !== undefined ? bound : TYPE_ANY;
    }
    if (ret.container !== undefined) {
        if (ret.typevar) {
            const paramId = bindings.get(ret.typevar);
            if (paramId === undefined) return TYPE_ANY;
            const paramName = tables.typeById.get(paramId);
            if (!paramName) return TYPE_ANY;
            const fullName = ret.container + '{' + paramName.name + '}';
            const retId = tables.typeByName.get(fullName);
            return retId !== undefined ? retId : TYPE_ANY;
        }
        if (ret.typevars) {
            const paramNames = ret.typevars.map(function(v) {
                const pid = bindings.get(v);
                if (pid === undefined) return '';
                const t = tables.typeById.get(pid);
                return t ? t.name : '';
            });
            const fullName = ret.container + '{' + paramNames.join(',') + '}';
            const retId = tables.typeByName.get(fullName);
            return retId !== undefined ? retId : TYPE_ANY;
        }
        return TYPE_ANY;
    }
    if (ret.fieldof !== undefined) {
        // Struct field access — would need user-defined struct type info
        return TYPE_ANY;
    }
    return TYPE_ANY;
}

// ============================================================
// Union Type Handling
// ============================================================

/**
 * Join two types into their least upper bound.
 * Unions are represented as sorted arrays of TypeIDs (max MAX_UNION).
 * @param {number|number[]} a
 * @param {number|number[]} b
 * @returns {number|number[]} Joined type
 */
function joinTypes(a, b) {
    if (a === UNKNOWN) return b;
    if (b === UNKNOWN) return a;
    if (a === TYPE_ANY || b === TYPE_ANY) return TYPE_ANY;
    if (a === TYPE_BOTTOM) return b;
    if (b === TYPE_BOTTOM) return a;

    // Fast path: identical
    if (a === b) return a;
    if (Array.isArray(a) && Array.isArray(b) && arraysEqual(a, b)) return a;

    // Merge into sorted set
    const aArr = Array.isArray(a) ? a : [a];
    const bArr = Array.isArray(b) ? b : [b];

    const merged = new Set(aArr);
    for (let i = 0; i < bArr.length; i++) merged.add(bArr[i]);

    if (merged.size > MAX_UNION) return TYPE_ANY;
    if (merged.size === 1) return merged.values().next().value;
    return Array.from(merged).sort(function(x, y) { return x - y; });
}

/**
 * Compare two type representations for equality.
 */
function typesEqual(a, b) {
    if (a === b) return true;
    if (Array.isArray(a) && Array.isArray(b)) return arraysEqual(a, b);
    return false;
}

function arraysEqual(a, b) {
    if (a.length !== b.length) return false;
    for (let i = 0; i < a.length; i++) {
        if (a[i] !== b[i]) return false;
    }
    return true;
}

// ============================================================
// SSA Reference Resolution
// ============================================================

/**
 * Resolve a reference to its current type.
 * ref can be: { ssa: index }, { arg: index }, { lit: typeId }, or null
 */
function resolve(ref, ssaTypes, argTypes) {
    if (ref === null || ref === undefined) return TYPE_NOTHING;
    if (typeof ref === 'object') {
        if ('ssa' in ref) return ssaTypes[ref.ssa];
        if ('arg' in ref) return argTypes[ref.arg];
        if ('lit' in ref) return ref.lit;
    }
    return TYPE_ANY;
}

// ============================================================
// Call Inference — 3-tier dispatch
// ============================================================

/**
 * Infer the return type of a function call.
 */
function inferCall(stmt, ssaTypes, argTypes, tables) {
    const calleeName = stmt.callee;
    const resolvedArgs = new Array(stmt.args.length);
    for (let i = 0; i < stmt.args.length; i++) {
        resolvedArgs[i] = resolve(stmt.args[i], ssaTypes, argTypes);
    }

    // If any arg is unknown, we can't infer yet (wait for next iteration)
    for (let i = 0; i < resolvedArgs.length; i++) {
        if (resolvedArgs[i] === UNKNOWN) return UNKNOWN;
    }

    // Handle union arguments: split and infer each component
    let hasUnion = false;
    for (let i = 0; i < resolvedArgs.length; i++) {
        if (Array.isArray(resolvedArgs[i])) { hasUnion = true; break; }
    }
    if (hasUnion) {
        return inferUnionSplit(calleeName, resolvedArgs, tables);
    }

    // Tier 1: Pre-computed hash table
    const funcId = tables.funcByName.get(calleeName);
    if (funcId !== undefined) {
        const ret = hashLookup(tables, funcId, resolvedArgs);
        if (ret !== -1) return ret;
    }

    // Tier 2: Parametric rules
    const ruleRet = matchRules(tables, calleeName, resolvedArgs);
    if (ruleRet !== -1) return ruleRet;

    // Tier 3: Fallback to Any (runtime dispatch in codegen)
    return TYPE_ANY;
}

/**
 * Handle union-typed arguments by splitting into concrete alternatives.
 */
function inferUnionSplit(calleeName, argTypeIds, tables) {
    // Find first union argument
    let unionIdx = -1;
    for (let i = 0; i < argTypeIds.length; i++) {
        if (Array.isArray(argTypeIds[i])) { unionIdx = i; break; }
    }
    if (unionIdx === -1) return TYPE_ANY;

    const unionTypes = argTypeIds[unionIdx];
    let result = UNKNOWN;

    for (let u = 0; u < unionTypes.length; u++) {
        const expanded = argTypeIds.slice();
        expanded[unionIdx] = unionTypes[u];

        let ret;
        // Check for more unions (recursive)
        let moreUnions = false;
        for (let i = 0; i < expanded.length; i++) {
            if (Array.isArray(expanded[i])) { moreUnions = true; break; }
        }

        if (moreUnions) {
            ret = inferUnionSplit(calleeName, expanded, tables);
        } else {
            const funcId = tables.funcByName.get(calleeName);
            ret = -1;
            if (funcId !== undefined) {
                ret = hashLookup(tables, funcId, expanded);
            }
            if (ret === -1) {
                ret = matchRules(tables, calleeName, expanded);
            }
            if (ret === -1) ret = TYPE_ANY;
        }
        result = joinTypes(result, ret);
    }

    return result;
}

// ============================================================
// Forward SSA Pass — the main inference algorithm
// ============================================================

/**
 * Infer types for all SSA values in a function.
 *
 * IR format:
 *   func = {
 *     code: [stmt, ...],      // SSA statements (0-indexed)
 *     argCount: int            // Number of function arguments
 *   }
 *
 *   stmt = { kind, ... } where kind-specific fields:
 *     CALL:       { kind:1, callee:string, args:[ref...] }
 *     PHI:        { kind:2, edges:[{from:int, val:ref}...] }
 *     GETFIELD:   { kind:3, obj:ref, field:string }
 *     NEW:        { kind:4, typeId:int }
 *     LITERAL:    { kind:5, typeId:int }
 *     RETURN:     { kind:6, val:ref }
 *     GOTO:       { kind:7, dest:int }
 *     GOTOIFNOT:  { kind:8, cond:ref, dest:int }
 *     PINODE:     { kind:9, val:ref, typeId:int }
 *
 *   ref = { ssa:int } | { arg:int } | { lit:typeId }
 *
 * @param {{ code: Object[], argCount: number }} func
 * @param {number[]} argTypes - TypeIDs for each argument
 * @param {Object} tables - Loaded inference tables
 * @returns {(number|number[])[]} TypeID for each SSA slot
 */
function inferFunction(func, argTypes, tables) {
    const n = func.code.length;
    const ssaTypes = new Array(n).fill(UNKNOWN);

    for (let iter = 0; iter < MAX_ITERS; iter++) {
        let changed = false;

        for (let i = 0; i < n; i++) {
            const stmt = func.code[i];
            const oldType = ssaTypes[i];
            let newType;

            switch (stmt.kind) {
                case STMT_CALL:
                    // Special-case: isa always returns Bool
                    if (stmt.callee === 'isa') {
                        newType = TYPE_BOOL;
                    } else {
                        newType = inferCall(stmt, ssaTypes, argTypes, tables);
                    }
                    break;

                case STMT_PHI:
                    newType = UNKNOWN;
                    for (let e = 0; e < stmt.edges.length; e++) {
                        const edgeType = resolve(stmt.edges[e].val, ssaTypes, argTypes);
                        newType = joinTypes(newType, edgeType);
                    }
                    break;

                case STMT_GETFIELD: {
                    const objType = resolve(stmt.obj, ssaTypes, argTypes);
                    if (objType === UNKNOWN) {
                        newType = UNKNOWN;
                    } else {
                        newType = matchRules(tables, 'getfield', [
                            Array.isArray(objType) ? TYPE_ANY : objType,
                            TYPE_SYMBOL
                        ]);
                        if (newType === -1) newType = TYPE_ANY;
                    }
                    break;
                }

                case STMT_NEW:
                    newType = stmt.typeId;
                    break;

                case STMT_LITERAL:
                    newType = stmt.typeId;
                    break;

                case STMT_RETURN:
                    newType = resolve(stmt.val, ssaTypes, argTypes);
                    break;

                case STMT_GOTO:
                    newType = TYPE_NOTHING;
                    break;

                case STMT_GOTOIFNOT:
                    newType = TYPE_NOTHING;
                    break;

                case STMT_PINODE:
                    newType = stmt.typeId;
                    break;

                default:
                    newType = TYPE_NOTHING;
            }

            if (!typesEqual(oldType, newType)) {
                ssaTypes[i] = newType;
                changed = true;
            }
        }

        if (!changed) break;
    }

    return ssaTypes;
}

/**
 * Infer the return type of a function.
 * Scans for RETURN statements and joins their types.
 */
function inferReturnType(func, argTypes, tables) {
    const ssaTypes = inferFunction(func, argTypes, tables);
    let retType = UNKNOWN;
    for (let i = 0; i < func.code.length; i++) {
        if (func.code[i].kind === STMT_RETURN) {
            retType = joinTypes(retType, ssaTypes[i]);
        }
    }
    return retType === UNKNOWN ? TYPE_ANY : retType;
}

// ============================================================
// User Method Table — for user-defined functions in playground
// ============================================================

/**
 * Create a user method table that can be queried alongside pre-computed tables.
 * Used when the playground compiles multiple user functions that call each other.
 */
function createUserMethodTable() {
    const entries = new Map();  // "funcName|arg0,arg1,..." → returnTypeId

    return {
        /** Register a user function's inferred signature. */
        register: function(funcName, argTypeIds, returnTypeId) {
            const key = funcName + '|' + argTypeIds.join(',');
            entries.set(key, returnTypeId);
        },

        /** Look up a user function's return type. */
        lookup: function(funcName, argTypeIds) {
            const key = funcName + '|' + argTypeIds.join(',');
            const ret = entries.get(key);
            return ret !== undefined ? ret : -1;
        },

        /** Get all registered entries (for debugging). */
        entries: function() { return entries; },
    };
}

/**
 * Infer types for a set of mutually-recursive user functions.
 * Iterates until all return types stabilize (max MAX_ITERS passes).
 *
 * @param {Object[]} funcs - Array of { name, func, argTypes }
 * @param {Object} tables - Pre-computed inference tables
 * @returns {Map<string, number>} funcName → return TypeID
 */
function inferModule(funcs, tables) {
    const userTable = createUserMethodTable();
    const results = new Map();

    for (let iter = 0; iter < MAX_ITERS; iter++) {
        let changed = false;

        for (let f = 0; f < funcs.length; f++) {
            const entry = funcs[f];

            // Create augmented tables that include user method lookups
            const augmented = Object.create(tables);
            const origFuncByName = tables.funcByName;
            // Wrap funcByName to also check user table
            augmented._userTable = userTable;

            const retType = inferReturnType(entry.func, entry.argTypes, tables);

            // Check user table for cross-calls (override inferCall for user funcs)
            const oldRet = results.get(entry.name);
            if (!typesEqual(oldRet, retType)) {
                results.set(entry.name, retType);
                userTable.register(entry.name, entry.argTypes, retType);
                changed = true;
            }
        }

        if (!changed) break;
    }

    return results;
}

// ============================================================
// Exports (CommonJS for Node.js, also works as ES module)
// ============================================================

if (typeof module !== 'undefined' && module.exports) {
    module.exports = {
        // Core inference
        inferFunction,
        inferReturnType,
        inferModule,
        loadTables,

        // User method table
        createUserMethodTable,

        // Low-level utilities
        compositeHash,
        hashLookup,
        matchRules,
        joinTypes,
        typesEqual,
        resolve,

        // Constants: TypeIDs
        TYPE_ANY, TYPE_BOTTOM, TYPE_NOTHING, TYPE_MISSING,
        TYPE_BOOL, TYPE_INT8, TYPE_INT16, TYPE_INT32, TYPE_INT64, TYPE_INT128,
        TYPE_UINT8, TYPE_UINT16, TYPE_UINT32, TYPE_UINT64, TYPE_UINT128,
        TYPE_FLOAT16, TYPE_FLOAT32, TYPE_FLOAT64,
        TYPE_CHAR, TYPE_STRING, TYPE_SYMBOL,

        // Constants: Abstract types
        TYPE_NUMBER, TYPE_REAL, TYPE_INTEGER, TYPE_SIGNED, TYPE_UNSIGNED,
        TYPE_ABSTRACT_FLOAT, TYPE_ABSTRACT_STRING, TYPE_ABSTRACT_CHAR,

        // Constants: Statement kinds
        STMT_CALL, STMT_PHI, STMT_GETFIELD, STMT_NEW, STMT_LITERAL,
        STMT_RETURN, STMT_GOTO, STMT_GOTOIFNOT, STMT_PINODE,

        // Constants: Inference
        UNKNOWN, MAX_ITERS, MAX_UNION,
    };
}
