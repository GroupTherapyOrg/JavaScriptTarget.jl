// worker.js — Web Worker for the Julia playground
// Runs compilation pipeline in a background thread:
//   parse → lower → infer → codegen → execute
//
// Messages IN:  { type: "compile", code: "...", id: N }
//               { type: "init", typesUrl: "types.bin" }
// Messages OUT: { type: "ready" }
//               { type: "result", id: N, js: "...", output: "...", diagnostics: [...], error: null|string, timeMs: N }
//
// Selfhost spec §7.4.

'use strict';

// Load pipeline components via importScripts (Web Worker API)
if (typeof importScripts === 'function') {
  importScripts('runtime.js', 'parser.js', 'lowerer.js', 'infer.js', 'codegen.js');
}

var _tables = null;
var _initialized = false;

/**
 * Load inference tables from types.bin ArrayBuffer.
 */
function initTables(buffer) {
  if (buffer && typeof JuliaInfer !== 'undefined' && JuliaInfer.loadTables) {
    _tables = JuliaInfer.loadTables(buffer);
  }
  _initialized = true;
}

/**
 * Compile Julia source code to JavaScript using the full pipeline.
 * Returns { js, output, diagnostics, error, timeMs }.
 */
function compileAndRun(source) {
  var t0 = performance.now();
  var diagnostics = [];
  var js = '';
  var output = '';
  var error = null;

  try {
    // Step 1: Compile using codegen.js pipeline (parse → lower → codegen)
    if (typeof JuliaCodegen === 'undefined' || !JuliaCodegen.compile) {
      throw new Error('JuliaCodegen not available');
    }

    var result = JuliaCodegen.compile(source, _tables);
    js = result.js || '';
    diagnostics = result.diagnostics || [];

    // Step 2: Execute the compiled JS and capture output
    // Prepend runtime overrides so jl_println captures output
    var execCode =
      'var _jl_output = [];\n' +
      'function jl_println() {\n' +
      '  var a = []; for (var i = 0; i < arguments.length; i++) {\n' +
      '    var v = arguments[i]; a.push(v === null ? "nothing" : v === undefined ? "missing" : String(v));\n' +
      '  }\n  _jl_output.push(a.join("") + "\\n");\n}\n' +
      'function jl_print() {\n' +
      '  var a = []; for (var i = 0; i < arguments.length; i++) {\n' +
      '    var v = arguments[i]; a.push(v === null ? "nothing" : v === undefined ? "missing" : String(v));\n' +
      '  }\n  _jl_output.push(a.join(""));\n}\n' +
      js + '\n' +
      '_jl_output.join("")';

    try {
      output = eval(execCode) || '';
    } catch (execErr) {
      error = execErr.name + ': ' + execErr.message;
    }
  } catch (compileErr) {
    error = compileErr.name + ': ' + compileErr.message;
    if (compileErr.diagnostics) {
      diagnostics = diagnostics.concat(compileErr.diagnostics);
    }
  }

  var timeMs = Math.round(performance.now() - t0);
  return { js: js, output: output, diagnostics: diagnostics, error: error, timeMs: timeMs };
}

// ============================================================
// Message Handler (Web Worker)
// ============================================================

if (typeof self !== 'undefined' && typeof self.onmessage !== 'undefined') {
  self.onmessage = function(e) {
    var msg = e.data;

    if (msg.type === 'init') {
      // Load types.bin
      if (msg.typesUrl) {
        fetch(msg.typesUrl)
          .then(function(r) { return r.arrayBuffer(); })
          .then(function(buf) {
            initTables(buf);
            self.postMessage({ type: 'ready' });
          })
          .catch(function(err) {
            // Continue without inference tables
            _initialized = true;
            self.postMessage({ type: 'ready', warning: 'types.bin not loaded: ' + err.message });
          });
      } else if (msg.buffer) {
        initTables(msg.buffer);
        self.postMessage({ type: 'ready' });
      } else {
        _initialized = true;
        self.postMessage({ type: 'ready' });
      }
      return;
    }

    if (msg.type === 'compile') {
      var result = compileAndRun(msg.code);
      result.type = 'result';
      result.id = msg.id;
      self.postMessage(result);
      return;
    }
  };
}

// ============================================================
// Node.js / CommonJS support (for testing)
// ============================================================

if (typeof module !== 'undefined' && module.exports) {
  module.exports = {
    initTables: initTables,
    compileAndRun: compileAndRun,
  };
}
