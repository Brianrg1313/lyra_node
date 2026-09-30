@Tags(["browser"])
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:lyra_node/lyra_node.dart';
import 'package:lyra_protocol/lyra_protocol.dart';
import 'package:test/test.dart';

import 'net_support.dart';
import 'support.dart';

/// The app's web build, served by a master, paired and signed in from a real Chrome
/// (`protocol-v1.md` §3): WebCrypto key, browser WebSocket, `device.prove`.
///
/// Opt-in, it needs Chrome and a web build:
/// `flutter build web --release --dart-define=LYRA_LAN=true --no-web-resources-cdn` in the app,
/// then `LYRA_WEB=<app>/build/web dart test test/browser_e2e_test.dart`. Chrome trusts the
/// server certificate by an SPKI pin here, standing in for the CA a person installs.
void main() {
  final web = Platform.environment["LYRA_WEB"];
  final chrome = Platform.environment["CHROME"] ?? r"C:\Program Files\Google\Chrome\Application\chrome.exe";

  test('a browser pairs by code, signs in, and proves itself again after a reload', () async {
    final master = await TestMaster.start(webRoot: web);
    final pin = base64.encode(Hashes.sha256(EcKeyPair.fromPem(master.server.transport.serverKeyPem).spki));
    final browser = await Browser.launch(chrome, pin: pin);
    addTearDown(browser.close);

    await browser.send("Runtime.enable");
    await browser.send("Log.enable");
    await browser.open("https://127.0.0.1:${master.port}/");
    // Flutter's code boxes read the keyboard only with the semantics tree off: the page is
    // given time to draw instead of being read.
    await browser.waitForView();

    final code = (await master.openPairing())["code"] as String;
    await browser.click(306, 387);
    await browser.type(code);
    await browser.click(503, 452);
    await browser.waitFor("Use the username and password");
    expect(master.openEngine.devices.list().map((device) => device.name), contains("Lyra Web"));

    // The key is a CryptoKey in IndexedDB that no script can read out.
    expect(await browser.evaluate("""new Promise((done, fail) => {
      const open = indexedDB.open('lyra-lan', 1);
      open.onerror = fail;
      open.onsuccess = () => {
        const get = open.result.transaction('keys', 'readonly').objectStore('keys').get('device');
        get.onsuccess = () => done([get.result.privateKey.extractable, get.result.privateKey.algorithm.namedCurve]);
      };
    })"""), [false, "P-256"]);

    await browser.click(503, 298);
    await browser.insert(owner.username);
    await browser.click(480, 348);
    await browser.insert(owner.password);
    await browser.click(503, 408);
    await browser.waitFor("Connected to the server");

    // A new page load is a new connection: the browser proves itself with the kept key and
    // picks up its session.
    await browser.send("Page.reload");
    await browser.waitForView();
    await browser.waitFor("Connected to the server");

    final (admin, _) = await master.signIn();
    final paired = master.openEngine.devices.list().firstWhere((device) => device.name == "Lyra Web");
    await admin.call(Ops.devicesRevoke, args: {"id": paired.id}, commandId: newId());
    await browser.waitFor("This device was removed");
  }, skip: web == null ? "set LYRA_WEB to a LAN web build" : false, timeout: const Timeout(Duration(minutes: 3)));
}

/// Headless Chrome driven over the DevTools protocol.
final class Browser {
  Browser._(this._process, this._profile, this._socket) {
    _socket.listen((frame) {
      final json = jsonDecode(frame as String) as Map<String, Object?>;
      final id = json["id"];
      if (id is int) _pending.remove(id)?.complete(json);
      // What went wrong in the page, should a step time out: uncaught errors and refusals
      // (a CSP violation, a failed request).
      final params = json["params"];
      if (json["method"] == "Runtime.exceptionThrown" ||
          json["method"] == "Log.entryAdded" && ((params as Map)["entry"] as Map)["level"] == "error") {
        print("browser: ${jsonEncode(params)}");
      }
    });
  }

  final Process _process;
  final Directory _profile;
  final WebSocket _socket;
  final Map<int, Completer<Map<String, Object?>>> _pending = {};
  int _next = 1;

  static Future<Browser> launch(String executable, {required String pin}) async {
    final profile = await Directory.systemTemp.createTemp("lyra-chrome");
    final process = await Process.start(executable, [
      "--headless=new",
      "--user-data-dir=${profile.path}",
      "--remote-debugging-port=0",
      "--ignore-certificate-errors-spki-list=$pin",
      "--window-size=1024,760",
      "--no-first-run",
      "about:blank",
    ]);
    unawaited(process.stdout.drain<void>());
    unawaited(process.stderr.drain<void>());

    final portFile = File("${profile.path}${Platform.pathSeparator}DevToolsActivePort");
    for (var i = 0; i < 100 && !portFile.existsSync(); i++) {
      await Future<void>.delayed(const Duration(milliseconds: 100));
    }
    final port = (await portFile.readAsLines()).first;

    final client = HttpClient();
    final request = await client.getUrl(Uri.parse("http://127.0.0.1:$port/json"));
    final targets = jsonDecode(await (await request.close()).transform(utf8.decoder).join()) as List;
    client.close();
    final page = targets.cast<Map<String, Object?>>().firstWhere((target) => target["type"] == "page");

    return Browser._(process, profile, await WebSocket.connect(page["webSocketDebuggerUrl"] as String));
  }

  Future<Map<String, Object?>> send(String method, [Map<String, Object?> params = const {}]) {
    final id = _next++;
    final answer = Completer<Map<String, Object?>>();
    _pending[id] = answer;
    _socket.add(jsonEncode({"id": id, "method": method, "params": params}));

    return answer.future.timeout(const Duration(seconds: 30));
  }

  Future<Object?> evaluate(String script) async {
    final answer = await send("Runtime.evaluate", {"expression": script, "awaitPromise": true, "returnByValue": true});
    final result = answer["result"] as Map<String, Object?>;
    if (result["exceptionDetails"] != null) throw StateError("$script: ${result["exceptionDetails"]}");

    return (result["result"] as Map<String, Object?>)["value"];
  }

  Future<void> click(double x, double y) async {
    for (final type in ["mousePressed", "mouseReleased"]) {
      await send("Input.dispatchMouseEvent", {"type": type, "x": x, "y": y, "button": "left", "clickCount": 1});
    }
    await Future<void>.delayed(const Duration(milliseconds: 300));
  }

  /// One key at a time, as a person types: Flutter's code boxes listen to key events.
  Future<void> type(String text) async {
    for (final char in text.split("")) {
      final code = char.codeUnitAt(0);
      final key = RegExp(r"\d").hasMatch(char) ? "Digit$char" : "Key${char.toUpperCase()}";
      await send("Input.dispatchKeyEvent", {"type": "keyDown", "text": char, "key": char, "code": key, "windowsVirtualKeyCode": char.toUpperCase().codeUnitAt(0), "nativeVirtualKeyCode": code});
      await send("Input.dispatchKeyEvent", {"type": "keyUp", "key": char, "code": key, "windowsVirtualKeyCode": char.toUpperCase().codeUnitAt(0)});
      await Future<void>.delayed(const Duration(milliseconds: 60));
    }
    await Future<void>.delayed(const Duration(milliseconds: 300));
  }

  /// Into the focused DOM text field (semantics on).
  Future<void> insert(String text) async {
    await send("Input.insertText", {"text": text});
    await Future<void>.delayed(const Duration(milliseconds: 300));
  }

  Future<void> open(String url) => send("Page.navigate", {"url": url});

  Future<void> waitForView() async {
    for (var i = 0; i < 120; i++) {
      if (await evaluate("!!document.querySelector('flutter-view flt-glass-pane')") == true) break;
      await Future<void>.delayed(const Duration(milliseconds: 250));
    }
    await Future<void>.delayed(const Duration(seconds: 2));
  }

  /// Flutter draws on a canvas; its semantics tree (switched on here) is what the DOM shows.
  Future<void> waitFor(String text, {Duration timeout = const Duration(seconds: 60)}) async {
    final end = DateTime.now().add(timeout);

    while (DateTime.now().isBefore(end)) {
      final found = await evaluate("""(() => {
        const placeholder = document.querySelector('flt-semantics-placeholder');
        if (placeholder) placeholder.click();
        return document.body.innerText.includes(${jsonEncode(text)}) ||
          [...document.querySelectorAll('[aria-label]')].some(e => e.getAttribute('aria-label').includes(${jsonEncode(text)}));
      })()""");
      if (found == true) return;
      await Future<void>.delayed(const Duration(milliseconds: 500));
    }

    await screenshot("timeout.png");
    throw TimeoutException("'$text' never showed");
  }

  Future<void> screenshot(String name) async {
    final shot = await send("Page.captureScreenshot");
    final data = (shot["result"] as Map<String, Object?>)["data"] as String;
    await File("${Directory.systemTemp.path}${Platform.pathSeparator}lyra-e2e-$name").writeAsBytes(base64.decode(data));
  }

  Future<void> close() async {
    await _socket.close();
    _process.kill();
    await _process.exitCode;
    try {
      await _profile.delete(recursive: true);
    } on FileSystemException {
      // Chrome may still hold a file for a moment; the temp folder is cleaned by the OS.
    }
  }
}
