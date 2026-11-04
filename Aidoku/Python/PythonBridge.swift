//
//  PythonBridge.swift
//  Aidoku
//
//  Embedded CPython runtime bridge.
//  Python is linked as a dynamic framework and embedded into the app bundle.
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

    var reportPath: String {
        let dir = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        return dir.appendingPathComponent("pycheck.json").path
    }

    private func writeReport(_ text: String) {
        try? text.write(toFile: reportPath, atomically: true, encoding: .utf8)
    }

    // must be called on `queue`
    private func prepareLocked() -> Bool {
        if ready { return true }
        let home = homePath
        setenv("PYTHONHOME", home, 1)
        setenv("PYTHONPATH", home + "/lib/python3.13", 1)
        setenv("PYTHONDONTWRITEBYTECODE", "1", 1)
        setenv("PYTHONUTF8", "1", 1)
        writeReport("{\"stage\":\"before-init\",\"home\":\"\(home)\"}")
        Py_Initialize()
        guard Py_IsInitialized() != 0 else {
            writeReport("{\"stage\":\"init-failed\"}")
            return false
        }
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
        writeReport("{\"stage\":\"selftest-begin\"}")
        let out = NSTemporaryDirectory() + "aidoku-pyout.json"
        try? FileManager.default.removeItem(atPath: out)
        let code = """
        import sys, json, os
        data = {
            "ok": True,
            "version": sys.version,
            "prefix": sys.prefix,
            "executable": sys.executable,
            "cwd": os.getcwd(),
        }
        open(r"\(out)", "w").write(json.dumps(data))
        """
        let rc = run(code)
        let body = (try? String(contentsOfFile: out, encoding: .utf8)) ?? "<no output>"
        let report = "{\"stage\":\"done\",\"rc\":\(rc),\"body\":\(body.debugDescription)}"
        writeReport(report)
        return report
    }
}
