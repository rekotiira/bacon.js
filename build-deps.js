var _ = require("lodash");
var fs = require("fs");
var path = require("path");

var dependenciesRegex = /#\s+build\-dependencies\s*:?\s*([a-zA-Z_, \t]*)/g;

function readDeps(contents) {
    var deps = [];
    var depsRegex = new RegExp(dependenciesRegex);
    var match;
    while (match = depsRegex.exec(contents)) {
      deps = deps.concat(match[1].split(/\s*[, \t]\s*/).map(function (x) { return x.trim(); }))
    }
    return deps
}


function readPiece(pieceName, pieceCache) {
  if (!pieceCache[pieceName]) {
    var contents = fs.readFileSync(path.join(__dirname, "src", pieceName + ".coffee"), "utf-8");

    // Put in cache
    pieceCache[pieceName] = {
      name: pieceName,
      deps: readDeps(contents),
      contents: contents,
    };
  }

  return pieceCache[pieceName];
}

function resolve(pieceNames, resolving, pieceCache) {
  resolving = resolving || [];

  return _.uniq(_.flatten(pieceNames.map(function(pieceName) {
    var piece = readPiece(pieceName, pieceCache);

    if (_.contains(resolving, pieceName)) {
      throw new Error("circular dependency resolving " + piece + "; stack: " + resolving.join(""));
    }

    var deps = _.chain(piece.deps)
      .map(function (x) { return resolve([x], resolving.concat([pieceName]), pieceCache) })
      .flatten()
      .value();

    return deps.concat([piece]);
  })))
}

module.exports.resolvePieces = function(pieceNames) {
  return resolve(pieceNames, [], {})
}
