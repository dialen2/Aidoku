//
//  PythonBridge.swift
//  Aidoku
//
//  Embedded CPython runtime bridge.
//
//  Why a dedicated thread instead of a DispatchQueue:
//  Py_Initialize() binds a PyThreadState to the *pthread* that ran it. GCD
//  serial queues do not guarantee the same thread between blocks, so a later
//  call can land on a worker with no thread state and segfault inside
//  _PyObject_Malloc (KERN_INVALID_ADDRESS at 0x10). A dedicated Thread keeps
//  pthread, thread state and GIL constant for the whole app lifetime.
//
//  Stack size is raised to 8 MB: iOS secondary threads default to 512 KB,
//  which is not enough headroom for the interpreter.
//

import Foundation

final class PythonBridge: @unchecked Sendable {
    static let shared = PythonBridge()

    private var thread: Thread?
    private let ioLock = NSLock()
    private let requestSem = DispatchSemaphore(value: 0)
    private let replySem = DispatchSemaphore(value: 0)
    private var pendingCode: String?
    private var pendingResult: Int32 = -1
    private var bootFailed = false

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

    // Runs on the dedicated python thread only.
    private func prepareOnWorker() {
        let home = homePath
        setenv("PYTHONHOME", home, 1)
        setenv("PYTHONPATH", home + "/lib/python3.13", 1)
        setenv("PYTHONDONTWRITEBYTECODE", "1", 1)
        setenv("PYTHONUTF8", "1", 1)
        setenv("PYTHONMALLOC", "malloc", 1)

        writeReport("{\"stage\":\"before-init\",\"home\":\"\(home)\"}")
        Py_Initialize()
        if Py_IsInitialized() == 0 {
            bootFailed = true
            writeReport("{\"stage\":\"init-failed\"}")
            return
        }
        // No PyEval_SaveThread: this thread is the only Python user, it keeps
        // the GIL from initialization to process exit.
        writeReport("{\"stage\":\"ready\",\"home\":\"\(home)\"}")
    }

    private func workerMain() {
        prepareOnWorker()
        while true {
            requestSem.wait()
            guard !bootFailed, let code = pendingCode else {
                pendingResult = -1
                replySem.signal()
                continue
            }
            pendingCode = nil
            pendingResult = PyRun_SimpleString(code)
            replySem.signal()
        }
    }

    private func ensureWorker() {
        guard thread == nil else { return }
        let worker = Thread { [weak self] in
            self?.workerMain()
        }
        worker.name = "app.aidoku.python"
        worker.stackSize = 8 * 1024 * 1024
        worker.qualityOfService = .userInitiated
        worker.start()
        thread = worker
    }

    /// Runs python source on the dedicated interpreter thread. Never blocks the main thread.
    func runAsync(_ code: String) async -> Int32 {
        await withCheckedContinuation { (continuation: CheckedContinuation<Int32, Never>) in
            DispatchQueue.global(qos: .userInitiated).async {
                self.ioLock.lock()
                self.ensureWorker()
                self.pendingCode = code
                self.requestSem.signal()
                self.replySem.wait()
                let rc = self.pendingResult
                self.ioLock.unlock()
                continuation.resume(returning: rc)
            }
        }
    }

    func selfTest() async -> String {
        let out = NSTemporaryDirectory() + "aidoku-pyout.json"
        try? FileManager.default.removeItem(atPath: out)
        let code = """
        import sys, json, os, threading
        mods = {}
        for _m in ("_struct", "_json", "_socket", "_ssl", "_hashlib", "zlib", "binascii",
                   "_datetime", "_csv", "_pickle", "unicodedata", "pyexpat", "_elementtree",
                   "_ctypes", "_sqlite3", "base64", "urllib.request"):
            try:
                __import__(_m)
                mods[_m] = "ok"
            except Exception as _e:
                mods[_m] = "FAIL: " + repr(_e)
        dyn = sys.prefix + "/lib/python3.13/lib-dynload"
        data = {
            "ok": True,
            "version": sys.version,
            "prefix": sys.prefix,
            "thread": threading.current_thread().name,
            "dynload_exists": os.path.isdir(dyn),
            "dynload_count": len(os.listdir(dyn)) if os.path.isdir(dyn) else 0,
            "modules": mods,
        }
        open(r"\(out)", "w").write(json.dumps(data, ensure_ascii=False))
        """
        let rc = await runAsync(code)
        let body = (try? String(contentsOfFile: out, encoding: .utf8)) ?? "<no output>"
        return "{\"stage\":\"done\",\"rc\":\(rc),\"body\":\(body.debugDescription)}"
    }
}
