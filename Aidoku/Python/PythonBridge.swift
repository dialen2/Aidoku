//
//  PythonBridge.swift
//  Aidoku
//
//  Embedded CPython runtime bridge.
//  Python is linked as a dynamic framework and embedded into the app bundle.
//  Every interpreter call is serialized on a background queue -- never the main thread.
//

import Foundation

final class PythonBridge: @unchecked Sendable {
    static let shared = PythonBridge()

    private let queue = DispatchQueue(label: "app.aidoku.python", qos: .userInitiated)
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

    /// Runs python source on the background queue. Never blocks the caller.
    func runAsync(_ code: String) async -> Int32 {
        await withCheckedContinuation { (continuation: CheckedContinuation<Int32, Never>) in
            queue.async {
                guard self.prepareLocked() else {
                    continuation.resume(returning: -1)
                    return
                }
                continuation.resume(returning: PyRun_SimpleString(code))
            }
        }
    }

    func selfTest() async -> String {
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
            "files": sorted(os.listdir(sys.prefix + "/lib/python3.13")),
        }
        open(r"\(out)", "w").write(json.dumps(data))
        """
        let rc = await runAsync(code)
        let body = (try? String(contentsOfFile: out, encoding: .utf8)) ?? "<no output>"
        return "{\"stage\":\"done\",\"rc\":\(rc),\"body\":\(body.debugDescription)}"
    }
}
