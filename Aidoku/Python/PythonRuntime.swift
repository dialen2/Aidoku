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
import sys, os, json, types, importlib.util, threading, traceback, base64

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
    if name in sys.modules:
        return sys.modules[name]
    spec = importlib.util.spec_from_file_location(name, path)
    mod = importlib.util.module_from_spec(spec)
    sys.modules[name] = mod
    spec.loader.exec_module(mod)
    return mod

def get_spider(path):
    with _LOCK:
        if path in _CACHE:
            return _CACHE[path]
        _install_stubs()
        mod = _load_module(path)
        cls = getattr(mod, 'Spider', None)
        if cls is None:
            raise RuntimeError('no Spider class in ' + path)
        spider = cls()
        try:
            spider.init('')
        except Exception:
            pass
        _CACHE[path] = spider
        return spider

def dispatch(script_b64, method_b64, args_b64):
    try:
        path = b64(script_b64)
        method = b64(method_b64)
        args = json.loads(b64(args_b64) or '{}')
        spider = get_spider(path)
        fn = getattr(spider, method, None)
        if fn is None:
            return json.dumps({'error': 'missing method: ' + method})
        try:
            result = fn(**args)
        except TypeError:
            result = fn(*args.values())
        return json.dumps({'data': result}, ensure_ascii=False, default=str)
    except Exception:
        return json.dumps({'error': traceback.format_exc()})

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
        guard rc == 0,
              let data = raw.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return ["error": "bridge failed rc=\(rc)"]
        }
        return obj
    }
}
