import 'dart:io';

import 'package:path/path.dart' as p;

/// The web build of the app, served by the master itself (plan §3): a page loaded from the
/// cloud can't call a LAN address, and this works with no internet at all.
///
/// Static files only. A path that isn't a file answers `index.html` (the app routes it), and a
/// path that climbs out of [root] is refused.
final class WebBundle {
  const WebBundle(this.root);

  final String root;

  /// The browser may load and connect only to this origin; the app runs as WebAssembly or
  /// JavaScript from it. No inline scripts, no frames around it.
  static const contentSecurityPolicy =
    "default-src 'self'; script-src 'self' 'wasm-unsafe-eval'; style-src 'self' 'unsafe-inline'; "
    "img-src 'self' data: blob:; font-src 'self' data:; connect-src 'self'; worker-src 'self' blob:; "
    "frame-ancestors 'none'; base-uri 'none'; form-action 'none'";

  static const _types = {
    ".html": "text/html; charset=utf-8",
    ".js": "text/javascript; charset=utf-8",
    ".mjs": "text/javascript; charset=utf-8",
    ".json": "application/json",
    ".wasm": "application/wasm",
    ".css": "text/css; charset=utf-8",
    ".png": "image/png",
    ".jpg": "image/jpeg",
    ".svg": "image/svg+xml",
    ".ico": "image/x-icon",
    ".otf": "font/otf",
    ".ttf": "font/ttf",
    ".woff2": "font/woff2",
    ".txt": "text/plain; charset=utf-8",
  };

  Future<void> serve(HttpRequest request) async {
    final response = request.response;
    final base = p.normalize(p.absolute(root));
    final relative = request.uri.pathSegments.where((segment) => segment.isNotEmpty).join("/");
    final candidate = p.normalize(p.join(base, relative));

    if (candidate != base && !p.isWithin(base, candidate)) {
      response.statusCode = HttpStatus.notFound;
      return response.close();
    }

    var file = File(candidate);
    if (!file.existsSync()) file = File(p.join(base, "index.html"));
    if (!file.existsSync()) {
      response.statusCode = HttpStatus.notFound;
      return response.close();
    }

    final extension = p.extension(file.path).toLowerCase();

    response.headers
      ..set("Content-Security-Policy", contentSecurityPolicy)
      ..set("X-Frame-Options", "DENY")
      ..contentType = ContentType.parse(_types[extension] ?? "application/octet-stream");
    // Everything but the entry points may be cached; they change with every build.
    if (!const {".html", ".json"}.contains(extension) && !p.basename(file.path).startsWith("flutter")) {
      response.headers.set("Cache-Control", "max-age=86400");
    }

    await response.addStream(file.openRead());
    await response.close();
  }
}
