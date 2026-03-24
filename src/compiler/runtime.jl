# Runtime JS code snippets that get included when needed.
# Tree-shakeable: only included if used by compiled functions.

const RUNTIME_EGAL = """
function jl_egal(a, b) {
  if (a === b) return true;
  if (a === null || b === null) return false;
  if (typeof a !== 'object' || typeof b !== 'object') return false;
  if (a.\$type !== b.\$type) return false;
  const keys = Object.keys(a);
  for (let i = 0; i < keys.length; i++) {
    if (!jl_egal(a[keys[i]], b[keys[i]])) return false;
  }
  return true;
}
"""

const RUNTIME_ERROR = """
class JlError extends Error {
  constructor(msg) {
    super(msg);
    this.name = 'JlError';
  }
}
"""
