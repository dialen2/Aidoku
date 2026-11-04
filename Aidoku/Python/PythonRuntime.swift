//
//  PythonRuntime.swift
//  Aidoku
//
//  Python-side helper module and dispatch layer.
//  All interpreter work happens off the main thread.
//

import Foundation

final class PythonRuntime {
    static let shared = PythonRuntime()

    private init() {}

    private var documents: String {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0].path
    }

    var bridgeDir: String { documents + "/pybridge" }
    var sourceDir: String { documents + "/pysrc" }

    private static let helperSource = #"""
import sys, os, json, types, importlib.util, threading, traceback, base64, io

# Embedded CPython ships without a CA bundle, so any https:// call would die on
# certificate verification. Spiders are scrapers, not banks: disable verification.
try:
    import ssl as _ssl
    _ssl._create_default_https_context = _ssl._create_unverified_context
except Exception:
    pass


def _build_requests_shim():
    import urllib.request as _ur, urllib.parse as _up, urllib.error as _ue, gzip as _gz, json as _js, ssl as _ss
    import types as _t

    class RequestException(IOError):
        pass

    class HTTPError(RequestException):
        pass

    class ConnectionError(RequestException):
        pass

    class Timeout(RequestException):
        pass

    class Response:
        def __init__(self, status, headers, content, url):
            self.status_code = status
            self.headers = headers
            self.content = content
            self.url = url
            self.encoding = None
            self.reason = ''
            self._decoded = None
        @property
        def ok(self):
            return 200 <= self.status_code < 400
        @property
        def text(self):
            if self._decoded is not None:
                return self._decoded
            enc = self.encoding
            ct = (self.headers.get('Content-Encoding') and '') or (self.headers.get('Content-Type') or '')
            low = ct.lower()
            if 'charset=' in low:
                enc = low.split('charset=')[1].split(';')[0].strip().strip('"').strip("'")
            if not enc:
                m = re.search(rb'charset=["\']?([\w-]+)', self.content[:4096], re.I)
                enc = m.group(1).decode('ascii', 'ignore') if m else 'utf-8'
            try:
                self._decoded = self.content.decode(enc, 'ignore')
            except LookupError:
                self._decoded = self.content.decode('utf-8', 'ignore')
            return self._decoded
        def json(self):
            return _js.loads(self.text)
        def close(self):
            return None
        def raise_for_status(self):
            if self.status_code >= 400:
                raise HTTPError('%s %s' % (self.status_code, self.url))
        def iter_content(self, chunk_size=8192, decode_unicode=False):
            n = max(1, int(chunk_size or 8192))
            for i in range(0, len(self.content), n):
                yield self.content[i:i + n]
        def __bool__(self):
            return self.ok
        def __repr__(self):
            return '<Response [%s]>' % self.status_code

    def _http(method, url, headers, data, params, proxies, timeout):
        if params:
            url = url + ('&' if '?' in url else '?') + _up.urlencode(params, doseq=True)
        body = None
        if data is not None:
            if isinstance(data, bytes):
                body = data
            elif isinstance(data, dict) or isinstance(data, list):
                body = _up.urlencode(data, doseq=True).encode('utf-8')
                if not any(k.lower() == 'content-type' for k in headers):
                    headers['Content-Type'] = 'application/x-www-form-urlencoded'
            else:
                body = str(data).encode('utf-8')
        req = _ur.Request(url, data=body, method=(method or 'GET').upper())
        for k, v in (headers or {}).items():
            try:
                req.add_header(k, str(v))
            except Exception:
                pass
        handlers = []
        if proxies:
            clean = {k: v for k, v in proxies.items() if v}
            if clean:
                handlers.append(_ur.ProxyHandler(clean))
        if str(url).lower().startswith('https'):
            handlers.append(_ur.HTTPSHandler(context=_ss._create_unverified_context()))
        opener = _ur.build_opener(*handlers)
        try:
            r = opener.open(req, timeout=(timeout or 20))
            raw = r.read()
            ce = (r.headers.get('Content-Encoding') or '').lower()
            if 'gzip' in ce:
                try:
                    raw = _gz.decompress(raw)
                except Exception:
                    pass
            return Response(r.status, r.headers, raw, r.geturl())
        except _ue.HTTPError as e:
            try:
                payload = e.read()
            except Exception:
                payload = b''
            return Response(e.code, e.headers, payload, url)
        except Exception as e:
            raise RequestException(str(e))

    class Session:
        def __init__(self):
            self.headers = {}
            self.cookies = {}
            self.proxies = None
            self.verify = False
            self.params = {}
        def _merge(self, kw):
            h = dict(self.headers)
            h.update(kw.pop('headers', None) or {})
            kw.pop('verify', None)
            kw.pop('allow_redirects', None)
            kw.pop('stream', None)
            px = kw.pop('proxies', None)
            if px is None:
                px = self.proxies
            pr = dict(self.params)
            pr.update(kw.pop('params', None) or {})
            j = kw.pop('json', None)
            d = kw.pop('data', None)
            if j is not None:
                d = _js.dumps(j)
                h['Content-Type'] = 'application/json'
            return h, d, pr, px
        def request(self, method, url, **kw):
            h, d, pr, px = self._merge(kw)
            return _http(method, url, h, d, pr, px, kw.get('timeout'))
        def get(self, url, **kw):
            return self.request('GET', url, **kw)
        def post(self, url, **kw):
            return self.request('POST', url, **kw)
        def put(self, url, **kw):
            return self.request('PUT', url, **kw)
        def delete(self, url, **kw):
            return self.request('DELETE', url, **kw)
        def head(self, url, **kw):
            return self.request('HEAD', url, **kw)
        def close(self):
            return None

    mod = _t.ModuleType('requests')
    exc = _t.ModuleType('requests.exceptions')
    for _n in ('RequestException', 'HTTPError', 'ConnectionError', 'Timeout'):
        setattr(exc, _n, locals()[_n])
        setattr(mod, _n, locals()[_n])
    mod.exceptions = exc
    mod.Session = Session
    mod.Response = Response
    mod.session = lambda: Session()

    def _top(method):
        def go(url, **kw):
            s = Session()
            return s.request(method, url, **kw)
        return go

    mod.get = _top('GET')
    mod.post = _top('POST')
    mod.put = _top('PUT')
    mod.delete = _top('DELETE')
    mod.head = _top('HEAD')
    return mod, exc


def _install_requests_shim():
    try:
        if 'requests' in sys.modules:
            return
        mod, exc = _build_requests_shim()
        sys.modules['requests'] = mod
        sys.modules['requests.exceptions'] = exc
    except Exception:
        pass


_install_requests_shim()

_LOCK = threading.Lock()
_CACHE = {}

def b64(s):
    return base64.b64decode(s.encode()).decode('utf-8')

def _install_stubs():
    if 'base.spider' in sys.modules:
        return
    base = types.ModuleType('base')
    spider = types.ModuleType('base.spider')

    class _StubSpider:
        def getCache(self, key):
            return None
        def setCache(self, key, value):
            return None
        def delCache(self, key):
            return None
        def init(self, extend=''):
            return None

    spider.Spider = _StubSpider
    base.spider = spider
    sys.modules['base'] = base
    sys.modules['base.spider'] = spider

def _load_module(path):
    name = 'aidoku_src_' + os.path.basename(path).replace('.', '_').replace('-', '_')
    cached = sys.modules.get(name)
    if cached is not None and getattr(cached, 'Spider', None) is not None:
        return cached
    sys.modules.pop(name, None)
    spec = importlib.util.spec_from_file_location(name, path)
    mod = importlib.util.module_from_spec(spec)
    sys.modules[name] = mod
    try:
        spec.loader.exec_module(mod)
    except BaseException:
        sys.modules.pop(name, None)
        raise
    if getattr(mod, 'Spider', None) is None:
        sys.modules.pop(name, None)
        raise RuntimeError('no Spider class in ' + path)
    return mod

def get_spider(path):
    with _LOCK:
        if path in _CACHE:
            return _CACHE[path]
        _install_stubs()
        mod = _load_module(path)
        cls = getattr(mod, 'Spider', None)
        spider = cls()
        try:
            spider.init('')
        except Exception:
            pass
        _CACHE[path] = spider
        return spider

def dispatch(script_b64, method_b64, args_b64):
    _buf = io.StringIO()
    _old_out, _old_err = sys.stdout, sys.stderr
    sys.stdout = sys.stderr = _buf
    try:
        path = b64(script_b64)
        method = b64(method_b64)
        args = json.loads(b64(args_b64) or '{}')
        spider = get_spider(path)
        fn = getattr(spider, method, None)
        if fn is None:
            return json.dumps({'error': 'missing method: ' + method, 'log': _buf.getvalue()})
        try:
            result = fn(**args)
        except TypeError:
            result = fn(*args.values())
        return json.dumps({'data': result, 'log': _buf.getvalue()}, ensure_ascii=False, default=str)
    except Exception:
        return json.dumps({'error': traceback.format_exc(), 'log': _buf.getvalue()})
    finally:
        sys.stdout, sys.stderr = _old_out, _old_err

def ping():
    return 'pong'
"""#

    private static let demoSource = #"""
import json

BASE = "https://picsum.photos"

class Spider:
    def init(self, extend=""):
        pass

    def searchContent(self, key, quick=False, pg="1"):
        q = key or "测试漫画"
        items = []
        for i in range(1, 13):
            items.append({
                "vod_id": str(i),
                "vod_name": "%s %02d" % (q, i),
                "vod_pic": "%s/seed/aidoku%d/300/400" % (BASE, i),
                "vod_remarks": "第 %d 卷" % i,
            })
        return {"list": items}

    def detailContent(self, ids):
        vid = str(ids[0]) if ids else "1"
        chapters = "#".join(["第%d话$%s-%d" % (i, vid, i) for i in range(1, 6)])
        return {"list": [{
            "vod_id": vid,
            "vod_name": "测试漫画 " + vid,
            "vod_pic": "%s/seed/aidoku%s/300/400" % (BASE, vid),
            "vod_content": "内置 demo 源，用于验证 Python -> Aidoku 通路。",
            "vod_play_url": chapters,
        }]}

    def playerContent(self, flag, id, vipFlags=None):
        pages = ["%s/seed/%s/800/1200" % (BASE, str(id) + "-" + str(i)) for i in range(1, 6)]
        return {"parse": 0, "url": "#".join(pages)}
"""#

    /// Creates the Documents layout and drops the helper + demo source. Pure Swift, no interpreter.
    func bootstrap() {
        let fm = FileManager.default
        try? fm.createDirectory(atPath: bridgeDir, withIntermediateDirectories: true)
        try? fm.createDirectory(atPath: sourceDir, withIntermediateDirectories: true)

        try? Self.helperSource.write(
            toFile: bridgeDir + "/pybridge.py",
            atomically: true,
            encoding: .utf8
        )

        let helperSize = (try? fm.attributesOfItem(atPath: bridgeDir + "/pybridge.py")[.size])
            .flatMap { $0 as? Int } ?? -1
        appendLog("bootstrap bridge=\(bridgeDir) helperBytes=\(helperSize)")

        let demoPath = sourceDir + "/demo.py"
        if !fm.fileExists(atPath: demoPath) {
            try? Self.demoSource.write(toFile: demoPath, atomically: true, encoding: .utf8)
        }
    }

    private func encode(_ s: String) -> String {
        Data(s.utf8).base64EncodedString()
    }

    private func appendLog(_ text: String) {
        let path = documents + "/pydispatch.log"
        let line = "[\(Date())] \(text)\n"
        if let handle = FileHandle(forWritingAtPath: path) {
            handle.seekToEndOfFile()
            handle.write(Data(line.utf8))
            handle.closeFile()
        } else {
            try? line.write(toFile: path, atomically: true, encoding: .utf8)
        }
    }

    /// Calls `method` on the `Spider` instance defined by the python source at `scriptPath`.
    func dispatch(scriptPath: String, method: String, args: [String: Any]) async -> [String: Any] {
        let argsJSON = (try? JSONSerialization.data(withJSONObject: args))
            .flatMap { String(data: $0, encoding: .utf8) } ?? "{}"

        let out = NSTemporaryDirectory() + "aidoku-dispatch.json"
        try? FileManager.default.removeItem(atPath: out)

        let code = """
        import sys, json
        sys.path.insert(0, r"\(bridgeDir)")
        try:
            import pybridge
            _r = pybridge.dispatch(r"\(encode(scriptPath))", r"\(encode(method))", r"\(encode(argsJSON))")
        except Exception:
            import traceback
            _r = json.dumps({'error': traceback.format_exc()})
        open(r"\(out)", "w", encoding="utf-8").write(_r)
        """
        appendLog("begin method=\(method) script=\(scriptPath)")
        let rc = await PythonBridge.shared.runAsync(code)
        let raw = (try? String(contentsOfFile: out, encoding: .utf8)) ?? "<no file>"
        appendLog("end method=\(method) rc=\(rc) out=\(raw.prefix(4000))")
        if let data = raw.data(using: .utf8),
           let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let pyLog = obj["log"] as? String,
           !pyLog.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            appendLog("pylog method=\(method): \(pyLog.prefix(3000))")
        }
        guard rc == 0,
              let data = raw.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return ["error": "bridge failed rc=\(rc)"]
        }
        return obj
    }
}
