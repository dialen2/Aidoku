//
//  PythonBridge.swift
//  Aidoku
//
//  Embedded CPython runtime bridge.
//  Python is linked as a static framework through the bridging header.
//

import Foundation

final class PythonBridge: @unchecked Sendable {
    static let shared = PythonBridge()

    private let queue = DispatchQueue(label: "app.aidoku.python")
    private var ready = false

    private init() {}

    var homePath: String {
        Bundle.main.bundlePath + "/python"
    }

    // must be called on `queue`
    private func prepareLocked() -> Bool {
        if ready { return true }
        let home = homePath
        setenv("PYTHONHOME", home, 1)
        setenv("PYTHONPATH", home + "/lib/python3.13", 1)
        setenv("PYTHONDONTWRITEBYTECODE", "1", 1)
        setenv("PYTHONUTF8", "1", 1)
        Py_Initialize()
        guard Py_IsInitialized() != 0 else { return false }
        ready = true
        return true
    }

    @discardableResult
    func prepare() -> Bool {
        queue.sync { prepareLocked() }
    }

    @discardableResult
    func run(_ code: String) -> Int32 {
        queue.sync {
            guard prepareLocked() else { return -1 }
            return PyRun_SimpleString(code)
        }
    }

    func selfTest() -> String {
        let out = NSTemporaryDirectory() + "aidoku-pycheck.json"
        try? FileManager.default.removeItem(atPath: out)
        let code = """
        import sys, json
        data = {"version": sys.version.split()[0], "prefix": sys.prefix, "ok": True}
        open(r"\(out)", "w").write(json.dumps(data))
        """
        let rc = run(code)
        let body = (try? String(contentsOfFile: out, encoding: .utf8)) ?? "<no output>"
        return "rc=\(rc) \(body)"
    }
}
