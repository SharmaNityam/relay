import Foundation
import Dispatch
let finished = DispatchSemaphore(value: 0)
Task {
    do {
        let client = EngineClient.shared
        let snapshot: SessionSnapshot = try await client.request("/api/sessions?demo=1")
        precondition(snapshot.total == 6)
        let acknowledgement: JobAcknowledgement = try await client.request("/api/repro", method: "POST", body: ["provider": "demo"])
        var job: ReproJob = try await client.request("/api/repro/\(acknowledgement.id)")
        for _ in 0..<100 where job.active {
            try await Task.sleep(nanoseconds: 200_000_000)
            job = try await client.request("/api/repro/\(acknowledgement.id)")
        }
        precondition(job.status == "reproduced", "baseline was \(job.status)")
        let test = job.test_code
        let _: JobAcknowledgement = try await client.request("/api/repro/\(job.id)/demo-fix", method: "POST", body: [:])
        job = try await client.request("/api/repro/\(job.id)")
        for _ in 0..<100 where job.active {
            try await Task.sleep(nanoseconds: 200_000_000)
            job = try await client.request("/api/repro/\(job.id)")
        }
        precondition(job.status == "verified")
        precondition(job.test_code == test)
        precondition(job.verification?.exit_code == 0)
        let zip = try await client.data("/api/repro/\(job.id)/download")
        precondition(zip.starts(with: [0x50, 0x4b]))
        print("Native typed client: 6 sessions, reproduced baseline, verified unchanged test, exit zero, ZIP evidence passed.")
    } catch {
        print("Native client failed: \(error)")
        exit(1)
    }
    finished.signal()
}
finished.wait()
